# frozen_string_literal: true

class SearchQueryParser < Parslet::Parser
  rule(:term)      { match('[^\s":]').repeat(1).as(:term) }
  rule(:quote)     { str('"') }
  rule(:colon)     { str(':') }
  rule(:space)     { match('\s').repeat(1) }
  rule(:operator)  { (str('+') | str('-')).as(:operator) }
  rule(:prefix)    { ((str('is') | str('has') | str('since') | str('until') | str('from') | str('scope')).as(:prefix) >> colon) }
  rule(:shortcode) { (colon >> term >> colon.maybe).as(:shortcode) }
  rule(:phrase)    { (quote >> (term >> space.maybe).repeat >> quote).as(:phrase) }
  rule(:clause)    { (operator.maybe >> prefix.maybe >> (phrase | term | shortcode)).as(:clause) }
  rule(:query)     { (clause >> space.maybe).repeat.as(:query) }
  root(:query)
end
