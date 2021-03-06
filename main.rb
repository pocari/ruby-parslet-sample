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
  rule(:query) { field.as(:field_list).maybe >> and_conditions }

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

EsQuery = Struct.new(:bool, :from, :size) do
  def initialize(bool, from = 0, size = 50)
    super
  end

  def eval
    # p [:EsQuery, bool]
    # とりあえずmax先頭1000件にしておく

    {
      from: from,
      size: size,
      query: bool.eval
    }
  end

  def add_must_condition(condition)
    case bool
    when MustQueries
      bool.queries << condition
    when Terms, ShouldQueries
      bool = MustQueries.new([bool, condition])
    else
      bool = condition
    end
  end

  def add_should_condition(condition)
    case bool
    when ShouldQueries
      bool.queries << condition
    when Terms, MulstQueries
      bool = ShouldQueries.new([bool, condition])
    else
      bool = condition
    end
  end
end

# "bool": {
#   "must" {
#     ...
#   }
# }
MustQueries = Struct.new(:queries) do
  def eval
    return queries.first.eval if queries.size == 1
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
    # コンテナ系(複数の条件をまとめる系)のクエリは複数クエリないと意味がないので、
    # 一つしかクエリがない場合は直接それを返す
    return queries.first.eval if queries.size == 1
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

# Transformのruleの中のselfはParslet::Contextオブジェクトなので、
# ruleの中での共通処理をTransformerクラスに定義しても使えない
#
# それ系のメソッドはこのmoduleに定義して仕込む
#
# またruleのブロックにブロック引数がついた場合はコンテキストが変わって
# transfomerクラス自身になるので、同時にTransformerクラスのクラスメソッド
# にもこのMethods moduleを仕込んでおけばどの書き方でも使えるようになる
# (この場合、ruleメソッドの引数でマッチした変数はローカル変数でなく
# ブロック引数にセットされているので注意
#
# 特異メソッドに仕込むのでincludeでなく、extendになるので注意
#
module CustomMethodsInRule

  # ruleブロック内で使いたい共通メソッドはこのmoduleに定義する
  module Methods
    def to_a(obj)
      # [obj]はArray(obj)にしないように。(objがhashの時に挙動が変わる)
      obj&.is_a?(Array) ? obj : [obj]
    end

    def build_field_query(fields, conditions)
      and_conditions = fields.map {|field|
        queries = conditions.map {|term|
          term.dup.tap {|obj|
            obj.field = field
          }
        }
        MustQueries.new(queries)
      }
      ShouldQueries.new(and_conditions)
    end
  end

  refine Parslet::Context do
    include Methods
  end
end

class ElasticSearchQueryTransformer < Parslet::Transform
  # ruleブロックに引数（変数情報）がある場合
  # => selfがElasticSearchQueryTransformerの場合の考慮
  extend CustomMethodsInRule::Methods

  # ruleブロックに引数がない場合
  # => selfがParslet::Contextの時用の考慮
  using CustomMethodsInRule

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
    # p [:or_conditions, values]
    Terms.new(to_a(values))
  }


  # and_conditions単体のhash
  # => field指定無しの場合
  # 予め決めたfield_listを設定しておく
  rule(and_conditions: subtree(:conditions)) {
    build_field_query(
      ["TODO_default_field1", "TODO_default_field2"],
      to_a(conditions)
    )
  }

  # ここがメイン部分
  #   field: 検索条件
  # の部分を処理する。
  # 例)
  #   - 一番シンブルパターン titleが わろてんか にマッチする
  #     title: わろてんか
  #   - 複数カラムのorパターン  title または subtitleがわろてんかにまっちする
  #     title,subtile: わろてんか
  #   - andパターン  titleが わろてんか かつ 5分 にマッチする
  #     title,subtile: わろてんか and 5分
  #   - andとorの複合パターン
  #     この際andの方が優先度低いので注意(a b and cが (a b) and (c) とみなされる)
  #     ただし、優先度に関してはパーサ側で考慮しているので、ここでは特に気にしなくても良い
  #     タイトルに「(半分 または わろてんかが含まれる) かつ (5分) が含まれる」
  #     title: 半分 わろてんか and 5分
  rule(
    field_list: subtree(:fields),
    and_conditions: subtree(:conditions)
  ) {
    # p [:and_cond, x, y, y.class]

    build_field_query(to_a(fields), to_a(conditions))
    # and_conditions = to_a(fields).map {|field|
    #   queries = to_a(conditions).map {|term|
    #     term.dup.tap {|obj|
    #       obj.field = field
    #     }
    #   }
    #   MustQueries.new(queries)
    # }
    # ShouldQueries.new(and_conditions)
  }

  rule(and_queries: subtree(:queries)) {
    #p [:and_queries, queries]
    EsQuery.new(MustQueries.new(to_a(queries)))
  }
end

raw = STDIN.read.chomp
# puts "------------------------ raw query"
puts raw
# 
begin
  parsed = QueryParser.new.parse(raw)
  # puts "------------------------ raw => syntax tree"
  pp parsed
rescue Parslet::ParseFailed => failure
  puts failure.parse_failure_cause.ascii_tree
  raise failure
end
# 
# puts "------------------------ syntax tree => es query"
ast = ElasticSearchQueryTransformer.new.apply(parsed)
pp [:ast, ast]

#パース後のトップレベルに条件追加
#ast.add_must_condition(Terms.new(%w(寄席の客), 'content'))
#pp [:ast, ast]
puts ast.eval.to_json
