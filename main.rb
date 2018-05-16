require 'parslet'
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
  rule(:query) { field.as(:field_list) >> or_conditions }

  rule(:field) { multi_field >> str(':') >> space? }
  rule(:multi_field)  { identifier.as(:field) >> (str(',') >> identifier.as(:field)).repeat }

  rule(:or_conditions)  { (and_conditions >> (or_op  >> and_conditions).repeat(1) | and_conditions).as(:or_conditions)}
  rule(:and_conditions) { (condition      >> (and_op >> condition     ).repeat(1) | condition     ).as(:and_conditions) }
  rule(:or_op) { (space >> str('or') >> space) | space }
  rule(:and_op) { space >> str('and') >> space}

  rule(:condition) { (quoted_string | raw_condition).as(:condition) >> str(':').absent? }
  rule(:raw_condition) {match('[^:\s]').repeat(1)}
  rule(:identifier) { match('[_0-9a-zA-Z]').repeat(1) }
end

class SimplyfySyntaxTreeTransformer < Parslet::Transform
  def self.simple_to_s_rule(sym)
    rule(sym => simple(:x)) { x.to_s }
  end
  simple_to_s_rule(:condition)
  simple_to_s_rule(:field)
  simple_to_s_rule(:str)
  simple_to_s_rule(:and_conditions)
  simple_to_s_rule(:and_query)

  rule(
    field_list: simple(:x),
    or_conditions: subtree(:y)
  ) {
    {
      field_list: Array(x),
      or_conditions: [y]
    }
  }
end

class ElasticSearchQueryTransformer < Parslet::Transform
end

raw = STDIN.read.chomp
puts "------------------------ raw query"
puts raw

puts "------------------------ raw => syntax tree"
begin
  parsed = QueryParser.new.parse(raw)
  pp parsed
rescue Parslet::ParseFailed => failure
  puts failure.parse_failure_cause.ascii_tree
  raise failure
end

puts "------------------------ syntax tree => simplyfy AST"
ast = SimplyfySyntaxTreeTransformer.new.apply(parsed)
pp ast

puts "------------------------ simplyfy AST => ElasticSearch Query"
# query = ElasticSearchQueryTransformer.new.apply(ast)
# pp query
puts "not implemented"

