# encoding: utf-8
# frozen_string_literal: true
# rubocop:disable Metrics/ModuleLength

module RuboCop
  module Cop
    # This module contains a collection of useful utility methods.
    module Util
      include PathUtil
      extend RuboCop::Sexp

      BYTE_ORDER_MARK = 0xfeff # The Unicode codepoint

      EQUALS_ASGN_NODES = [:lvasgn, :ivasgn, :cvasgn, :gvasgn,
                           :casgn, :masgn].freeze
      SHORTHAND_ASGN_NODES = [:op_asgn, :or_asgn, :and_asgn].freeze
      ASGN_NODES = (EQUALS_ASGN_NODES + SHORTHAND_ASGN_NODES).freeze

      # http://phrogz.net/programmingruby/language.html#table_18.4
      # Backtick is added last just to help editors parse this code.
      OPERATOR_METHODS = %w(
        | ^ & <=> == === =~ > >= < <= << >>
        + - * / % ** ~ +@ -@ [] []= ! != !~
      ).map(&:to_sym).push(:'`').freeze

      # Match literal regex characters, not including anchors, character
      # classes, alternatives, groups, repetitions, references, etc
      LITERAL_REGEX = /[\w\s\-,"'!#%&<>=;:`~]|\\[^AbBdDgGhHkpPRwWXsSzZS0-9]/

      module_function

      def operator?(symbol)
        OPERATOR_METHODS.include?(symbol)
      end

      def strip_quotes(str)
        if str[0] == '"' || str[0] == "'"
          str[0] = ''
        else
          # we're dealing with %q or %Q
          str[0, 3] = ''
        end
        str[-1] = ''

        str
      end

      def block_length(block_node)
        block_node.loc.end.line - block_node.loc.begin.line
      end

      def comment_line?(line_source)
        line_source =~ /^\s*#/
      end

      def line_range(arg)
        source_range = case arg
                       when Parser::Source::Range
                         arg
                       when Parser::AST::Node
                         arg.source_range
                       else
                         raise ArgumentError, "Invalid argument #{arg}"
                       end

        source_range.begin.line..source_range.end.line
      end

      def parentheses?(node)
        node.loc.respond_to?(:end) && node.loc.end &&
          node.loc.end.is?(')'.freeze)
      end

      def parenthesized_call?(send)
        send.loc.begin && send.loc.begin.is?('(')
      end

      def on_node(syms, sexp, excludes = [], &block)
        return to_enum(:on_node, syms, sexp, excludes) unless block_given?

        yield sexp if Array(syms).include?(sexp.type)
        return if Array(excludes).include?(sexp.type)

        sexp.each_child_node { |elem| on_node(syms, elem, excludes, &block) }
      end

      def source_range(source_buffer, line_number, column, length = 1)
        if column.is_a?(Range)
          column_index = column.begin
          length = numeric_range_size(column)
        else
          column_index = column
        end

        line_begin_pos = if line_number.zero?
                           0
                         else
                           source_buffer.line_range(line_number).begin_pos
                         end
        begin_pos = line_begin_pos + column_index
        end_pos = begin_pos + length

        Parser::Source::Range.new(source_buffer, begin_pos, end_pos)
      end

      # Returns the column attribute of the range, except if the range is on
      # the first line and there's a byte order mark at the beginning of that
      # line, in which case 1 is subtracted from the column value. This gives
      # the column as it appears when viewing the file in an editor.
      def effective_column(range)
        if range.line == 1 &&
           @processed_source.raw_source.codepoints.first == BYTE_ORDER_MARK
          range.column - 1
        else
          range.column
        end
      end

      def range_with_surrounding_comma(range, side = :both)
        buffer = @processed_source.buffer
        src = buffer.source

        go_left, go_right = directions(side)

        begin_pos = range.begin_pos
        end_pos = range.end_pos
        begin_pos = move_pos(src, begin_pos, -1, go_left, /,/)
        end_pos = move_pos(src, end_pos, 1, go_right, /,/)

        Parser::Source::Range.new(buffer, begin_pos, end_pos)
      end

      def range_with_surrounding_space(range, side = :both, with_newline = true)
        buffer = @processed_source.buffer
        src = buffer.source

        go_left, go_right = directions(side)

        begin_pos = range.begin_pos
        end_pos = range.end_pos
        begin_pos = move_pos(src, begin_pos, -1, go_left, /[ \t]/)
        begin_pos = move_pos(src, begin_pos, -1, go_left && with_newline, /\n/)
        end_pos = move_pos(src, end_pos, 1, go_right, /[ \t]/)
        end_pos = move_pos(src, end_pos, 1, go_right && with_newline, /\n/)
        Parser::Source::Range.new(buffer, begin_pos, end_pos)
      end

      def move_pos(src, pos, step, condition, regexp)
        offset = step == -1 ? -1 : 0
        pos += step while condition && src[pos + offset] =~ regexp
        pos < 0 ? 0 : pos
      end

      def directions(side)
        if side == :both
          [true, true]
        else
          [side == :left, side == :right]
        end
      end

      def begins_its_line?(range)
        (range.source_line =~ /\S/) == range.column
      end

      def ends_its_line?(range)
        line = range.source_buffer.source_line(range.last_line)
        (line =~ /\s*\z/) == range.last_column
      end

      def within_node?(inner, outer)
        o = outer.is_a?(Node) ? outer.source_range : outer
        i = inner.is_a?(Node) ? inner.source_range : inner
        i.begin_pos >= o.begin_pos && i.end_pos <= o.end_pos
      end

      # Returns, for example, a bare `if` node if the given node is an `if`
      # with calls chained to the end of it.
      def first_part_of_call_chain(node)
        while node
          case node.type
          when :send
            receiver, _method_name, _args = *node
            node = receiver
          when :block
            method, _args, _body = *node
            node = method
          else
            break
          end
        end
        node
      end

      # Range#size is not available prior to Ruby 2.0.
      def numeric_range_size(range)
        size = range.end - range.begin
        size += 1 unless range.exclude_end?
        size = 0 if size < 0
        size
      end

      # If converting a string to Ruby string literal source code, must
      # double quotes be used?
      def double_quotes_required?(string)
        # Double quotes are required for strings which either:
        # - Contain single quotes
        # - Contain non-printable characters, which must use an escape

        # Regex matches IF there is a ' or there is a \\ in the string that is
        # not preceded/followed by another \\ (e.g. "\\x34") but not "\\\\".
        string =~ /'|(?<! \\) \\{2}* \\ (?![\\"])/x
      end

      # If double quoted string literals are found in Ruby code, and they are
      # not the preferred style, should they be flagged?
      def double_quotes_acceptable?(string)
        # If a string literal contains hard-to-type characters which would
        # not appear on a "normal" keyboard, then double-quotes are acceptable
        needs_escaping?(string) ||
          string.codepoints.any? { |cp| cp < 32 || cp > 126 }
      end

      def needs_escaping?(string)
        double_quotes_required?(escape_string(string))
      end

      def escape_string(string)
        string.inspect[1..-2].tap { |s| s.gsub!(/\\"/, '"') }
      end

      def to_string_literal(string)
        if needs_escaping?(string)
          string.inspect
        else
          "'#{string.gsub('\\') { '\\\\' }}'"
        end
      end

      def to_symbol_literal(string)
        ":#{string.to_sym}"
      end

      def interpret_string_escapes(string)
        StringInterpreter.interpret(string)
      end

      def same_line?(n1, n2)
        n1.respond_to?(:loc) &&
          n2.respond_to?(:loc) &&
          n1.loc.line == n2.loc.line
      end

      def line_distance(n1, n2)
        n2.loc.line - n1.loc.line
      end

      def preceed?(n1, n2)
        line_distance(n1, n2) == 1
      end

      def stripped_source_upto(line)
        processed_source[0..line].map(&:strip)
      end
    end
  end
end
