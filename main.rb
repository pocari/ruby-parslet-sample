require 'parslet'
require 'json'
require 'pry-byebug'

class BaseParser < Parslet::Parser
  rule(:space) { match('\s').repeat(1) }
  rule(:space?) { space.maybe }

  rule(:quoted_string) { d_quoted_string | s_quoted_string }

  rule(:escaped_char) { str('\\') >> any }
  rule(:d_quote) { str('"') }
  rule(:d_quoted_string) { d_quote >> (escaped_char | d_quote.absent? >> any).repeat.as(:str) >> d_quote }

  rule(:s_quote) { str('\'') }
  rule(:s_quoted_string) { s_quote >> (escaped_char | s_quote.absent? >> any).repeat.as(:str) >> s_quote }
end

class QueryParser < BaseParser
  root(:and_queries)

  rule(:and_queries) { (query.as(:and_query) >> (space >> query.as(:and_query)).repeat).as(:and_queries) >> space?}
  rule(:query) { field.as(:field_list) >> and_conditions }

  rule(:field) { multi_field >> str(':') >> space? }
  rule(:multi_field)  { identifier.as(:field) >> (str(',') >> identifier.as(:field)).repeat }

  # 普通の言語とandとorの優先度が逆になっている(andの方が優先度が低い)ので注意
  rule(:and_conditions) { (or_conditions >> (and_op >> or_conditions).repeat).as(:and_conditions)}
  rule(:or_conditions)  { (condition     >> (or_op  >> condition    ).repeat).as(:or_conditions) }
  rule(:or_op) { (space >> str('or') >> space) | space }
  rule(:and_op) { space >> str('and') >> space }

  rule(:condition) { (quoted_string | raw_condition).as(:condition) >> str(':').absent? }
  # ここで特別にandを無視しておかないと検索ワードとしてandが含まれてしまうため除く
  # andを値として使いたい場合は"", ''で囲ってquoted_string側に入るようにする
  rule(:raw_condition) { str('and').absent? >> match('[^:\s]').repeat(1) }
  rule(:identifier) { match('[_0-9a-zA-Z.]').repeat(1) }
end

EsQuery = Struct.new(:bool) do
  def eval
    # p [:EsQuery, bool]
    {
      query: bool.eval
    }
  end
end

# "bool": {
#   "must" {
#     ...
#   }
# }
MustQueries = Struct.new(:queries) do
  def eval
    # p [:Must, queries.size, queries]
    {
      bool: {
        must: queries.map(&:eval)
      }
    }
  end
end

# "bool": {
#   "should" {
#     ...
#   }
# }
ShouldQueries = Struct.new(:queries) do
  def eval
    # p [:Should, queries.size, queries]
    {
      bool: {
        should: queries.map(&:eval)
      }
    }
  end
end

# "terms" : {
#   #{field}: #{values}
#  }
Terms = Struct.new(:values, :field) do
  def eval
    # p [:Terma, field, values]
    {
      terms: {
        field => values
      }
    }
  end
end

class ElasticSearchQueryTransformer < Parslet::Transform
  def self.simple_to_s_rule(sym)
    rule(sym => simple(:x)) { x.to_s }
  end

  # 単一の文字列になるような値はそこまでシンプルにしておく
  # 例) 検索文字列は単純な文字列の場合と、quoteされた文字列の場合があり
  #    それぞれ構文木上は、
  #      あああ   => { condition: 'あああ'          }
  #      'いいい' => { condition: { str: 'いいい' } }
  #    となるが、ASTの段階では、単純に
  #        あああ
  #        いいい
  #    で十分なので、その状態に変換する(fieldも同じ)
  simple_to_s_rule(:condition)
  simple_to_s_rule(:field)
  simple_to_s_rule(:str)

  # topレベル直下の条件の配列はすべてand(es上はmust)でつなぐので、
  # { and_query => object }
  # はobjectだけあれば、わかるため、これもシンプルにする
  rule(and_query: subtree(:x)) { x }

  # 「title: aa bb cc」で、titleがaaまたはbbまたはccにマッチする
  # の意味になるので、esの
  # terms: {
  #   field: [
  #     val1,
  #     val2,
  #     ...
  #   ]
  # }
  # に変換する。fieldは上のレベルなので、あとでセットしてもらう
  rule(or_conditions: subtree(:values)) {
    p [:or_conditions, values]
    value2 = values.is_a?(Array) ? values : [values]
    Terms.new(value2)
  }

  # ここがメイン部分
  #   field: 検索条件
  # の部分を処理する。
  # 例)
  #   - 一番シンブルパターン titleが わろてんか にマッチする
  #     title: わろてんか
  #   - 複数カラムのorパターン  title または subtitleがわろてんかにまっちする
  #     title,subtile: わろてんか
  #   - andパターン  titleが わろてんか かつ 5分 にまっちする
  #     title,subtile: わろてんか and 5分
  #   - andとorの複合パターン(
  #     この際andの方が優先度低いので注意(a b and cが (a b) and (c) とみなされる)
  #     ただし、優先度に関してはパーサ側で考慮しているので、ここでは特に気にしなくても良い
  #     title: わろてんか 
  rule(
    field_list: subtree(:x),
    and_conditions: subtree(:y)
  ) {
    # p [:and_cond, x, y, y.class]

    # Array(y) だと結果が変わるので注意
    xx = x.is_a?(Array) ? x : [x]
    yy = y.is_a?(Array) ? y : [y]

    and_conditions = xx.map {|field|
      queries = yy.map {|term|
        term.dup.tap {|obj|
          obj.field = field
        }
      }
      MustQueries.new(queries)
    }
    ShouldQueries.new(and_conditions)
  }

  rule(and_queries: subtree(:queries)) {
    #p [:and_queries, queries]
    normalized = queries.is_a?(Array) ? queries : [queries]
    eq = EsQuery.new(MustQueries.new(normalized))
    # p [:es_query, eq]
    eq
  }
end

raw = STDIN.read.chomp
puts "------------------------ raw query"
puts raw
# 
begin
  parsed = QueryParser.new.parse(raw)
  puts "------------------------ raw => syntax tree"
  pp parsed
rescue Parslet::ParseFailed => failure
  puts failure.parse_failure_cause.ascii_tree
  raise failure
end
# 
# puts "------------------------ syntax tree => es query"
ast = ElasticSearchQueryTransformer.new.apply(parsed)
#pp [:ast, ast]

puts ast.eval.to_json
