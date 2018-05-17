require 'parslet'
require 'pry-byebug'
include Parslet

def parse(parser, value)
  parser.parse(value)
rescue Parslet::ParseFailed => failure
  puts failure.parse_failure_cause.ascii_tree
  raise failure
end

# sample
abc_parser = str('abc')

binding.pry
p abc_parser
