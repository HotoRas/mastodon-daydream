# frozen_string_literal: true

class SearchQueryTransformer < Parslet::Transform
  class Query
    attr_reader :should_clauses, :must_not_clauses, :must_clauses, :filter_clauses, :range_clauses, :scope_clauses

    def initialize(clauses)
      grouped = clauses.group_by(&:operator).to_h
      @should_clauses = grouped.fetch(:should, [])
      @must_not_clauses = grouped.fetch(:must_not, [])
      @must_clauses = grouped.fetch(:must, [])
      @filter_clauses = grouped.fetch(:filter, [])
      @range_clauses = grouped.fetch(:range, [])
      @scope_clauses = grouped.fetch(:scope, [])
    end

    def apply(search)
      should_clauses.each { |clause| search = search.query.should(clause_to_query(clause)) }
      must_clauses.each { |clause| search = search.query.must(clause_to_query(clause)) }
      must_not_clauses.each { |clause| search = search.query.must_not(clause_to_query(clause)) }
      filter_clauses.each { |clause| search = search.filter(**clause_to_filter(clause)) }
      range_clauses.each { |clause| search = search.filter(**clause_to_range(clause)) }
      search.query.minimum_should_match(1)
    end

    def scope
      case scope_clauses.last&.term
      when 'related', nil
        :related
      when 'public'
        :public
      else
        raise Mastodon::SyntaxError, "Unknown scope: #{scope_clauses.last.term}"
      end
    end

    private

    def clause_to_query(clause)
      case clause
      when TermClause
        { multi_match: { type: 'most_fields', query: clause.term, fields: ['text', 'text.stemmed'] } }
      when PhraseClause
        { match_phrase: { text: { query: clause.phrase } } }
      when PrefixClause
        { clause.query => { clause.filter => clause.term } }
      else
        raise "Unexpected clause type: #{clause}"
      end
    end

    def clause_to_filter(clause)
      case clause
      when PrefixClause
        { term: { clause.filter => clause.term } }
      else
        raise "Unexpected clause type: #{clause}"
      end
    end

    def clause_to_range(clause)
      case clause
      when PrefixClause
        { range: { clause.filter => clause.term } }
      else
        raise "Unexpected clause type: #{clause}"
      end
    end
  end

  class Operator
    class << self
      def symbol(str)
        case str
        when '+'
          :must
        when '-'
          :must_not
        when nil
          :should
        else
          raise Mastodon::SyntaxError, "Unknown operator: #{str}"
        end
      end

      def filter_context_symbol(str)
        case str
        when '+', nil
          :filter
        when '-'
          :must_not
        else
          raise Mastodon::SyntaxError, "Unknown operator: #{str}"
        end
      end
    end
  end

  class TermClause
    attr_reader :prefix, :operator, :term

    def initialize(prefix, operator, term)
      @prefix = prefix
      @operator = Operator.symbol(operator)
      @term = term
    end
  end

  class PhraseClause
    attr_reader :prefix, :operator, :phrase

    def initialize(prefix, operator, phrase)
      @prefix = prefix
      @operator = Operator.symbol(operator)
      @phrase = phrase
    end
  end

  class PrefixClause
    attr_reader :filter, :operator, :term, :query

    def initialize(prefix, operator, term)
      @query = :term
      @operator = Operator.filter_context_symbol(operator)
      case prefix
      when 'from'
        @filter = :account_id

        username, domain = term.gsub(/\A@/, '').split('@')
        domain           = nil if TagManager.instance.local_domain?(domain)
        account          = Account.find_remote!(username, domain)

        @term = account.id
      when 'since'
        @filter = :created_at
        @operator = :range
        @term = { gte: Time.parse(term).utc.iso8601 }
      when 'until'
        @filter = :created_at
        @operator = :range
        @term = { lte: Time.parse(term).utc.iso8601 }
      when 'is'
        @filter = :is
        @term = term
      when 'has'
        @filter = :has
        @term = term
      when 'scope'
        @operator = :scope
        @term = term
      else
        raise Mastodon::SyntaxError
      end
    end
  end

  rule(clause: subtree(:clause)) do
    prefix   = clause[:prefix]&.to_s
    operator = clause[:operator]&.to_s

    if clause[:prefix]
      PrefixClause.new(prefix, operator, clause[:term].to_s)
    elsif clause[:term]
      TermClause.new(prefix, operator, clause[:term].to_s)
    elsif clause[:shortcode]
      TermClause.new(prefix, operator, ":#{clause[:term]}:")
    elsif clause[:phrase]
      PhraseClause.new(prefix, operator, clause[:phrase].is_a?(Array) ? clause[:phrase].map { |p| p[:term].to_s }.join(' ') : clause[:phrase].to_s)
    else
      raise Mastodon::SyntaxError, "Unexpected clause type: #{clause}"
    end
  end

  rule(query: sequence(:clauses)) { Query.new(clauses) }
end
