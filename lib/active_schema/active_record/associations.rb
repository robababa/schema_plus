require 'ostruct'

module ActiveSchema
  module ActiveRecord
    module Associations

      def self.extended(base)
        class << base
          alias_method_chain :reflect_on_association, :active_schema
          alias_method_chain :reflect_on_all_associations, :active_schema
        end
      end

      def reflect_on_association_with_active_schema(*args)
        _load_active_schema_associations unless @active_schema_associations_loaded
        reflect_on_association_without_active_schema(*args)
      end

      def reflect_on_all_associations_with_active_schema(*args)
        _load_active_schema_associations unless @active_schema_associations_loaded
        reflect_on_all_associations_without_active_schema(*args)
      end

      def define_attribute_methods(*args)
        super
        _load_active_schema_associations unless @active_schema_associations_loaded
      end

      private

      def _load_active_schema_associations
        @active_schema_associations_loaded = true
        return unless active_schema_config.associations.auto_create?

        reverse_foreign_keys.each do | foreign_key |
          if foreign_key.table_name =~ /^#{table_name}_(.*)$/ || foreign_key.table_name =~ /^(.*)_#{table_name}$/
            other_table = $1
            if other_table == other_table.pluralize and connection.columns(foreign_key.table_name).any?{|col| col.name == "#{other_table.singularize}_id"}
              _define_association(:has_and_belongs_to_many, foreign_key, other_table)
            else
              _define_association(:has_one_or_many, foreign_key)
            end
          else
            _define_association(:has_one_or_many, foreign_key)
          end
        end

        foreign_keys.each do | foreign_key |
          _define_association(:belongs_to, foreign_key)
        end
      end

      def _define_association(macro, fk, referencing_table_name = nil)
        return unless fk.column_names.size == 1

        referencing_table_name ||= fk.table_name

        column_name = fk.column_names.first
        reference_name = column_name.sub(/_id$/, '')
        references_name = fk.references_table_name.singularize
        referencing_name = referencing_table_name.singularize

        references_class_name = references_name.classify
        referencing_class_name = referencing_name.classify

        references_concise = _concise_name(references_name, referencing_name)
        referencing_concise = _concise_name(referencing_name, references_name)

        case reference_name
        when 'parent'
          belongs_to         = 'parent'
          belongs_to_concise = 'parent'

          has_one            = 'child'
          has_one_concise    = 'child'

          has_many           = 'children'
          has_many_concise   = 'children'

        when references_name
          belongs_to         = references_name
          belongs_to_concise = references_concise

          has_one            = referencing_name
          has_one_concise    = referencing_concise

          has_many           = referencing_name.pluralize
          has_many_concise   = referencing_concise.pluralize

        when /(.*)_#{references_name}$/, /(.*)_#{references_concise}$/
          label = $1
          belongs_to         = "#{label}_#{references_name}"
          belongs_to_concise = "#{label}_#{references_concise}"

          has_one            = "#{referencing_name}_as_#{label}"
          has_one_concise    = "#{referencing_concise}_as_#{label}"

          has_many           = "#{referencing_name.pluralize}_as_#{label}"
          has_many_concise   = "#{referencing_concise.pluralize}_as_#{label}"

        when /^#{references_name}_(.*)$/, /^#{references_concise}_(.*)$/
          label = $1
          belongs_to            = "#{references_name}_#{label}"
          belongs_to_concise    = "#{references_concise}_#{label}"

          has_one               = "#{referencing_name}_as_#{label}"
          has_one_concise       = "#{referencing_concise}_as_#{label}"

          has_many              = "#{referencing_name.pluralize}_as_#{label}"
          has_many_concise      = "#{referencing_concise.pluralize}_as_#{label}"

        else
          belongs_to            = reference_name
          belongs_to_concise    = reference_name

          has_one               = "#{referencing_name}_as_#{reference_name}"
          has_one_concise       = "#{referencing_concise}_as_#{reference_name}"

          has_many              = "#{referencing_name.pluralize}_as_#{reference_name}"
          has_many_concise      = "#{referencing_concise.pluralize}_as_#{reference_name}"
        end

        case macro
        when :has_and_belongs_to_many
          name = has_many
          name_concise = has_many_concise
          opts = {:class_name => referencing_class_name, :join_table => fk.table_name, :foreign_key => column_name}
        when :belongs_to
          name = belongs_to
          name_concise = belongs_to_concise
          opts = {:class_name => references_class_name, :foreign_key => column_name}
        when :has_one_or_many
          opts = {:class_name => referencing_class_name, :foreign_key => column_name}
          # use connection.indexes and connection.colums rather than class
          # methods of the referencing class because using the class
          # methods would require getting the class -- which might trigger
          # an autoload which could start some recursion making things much
          # harder to debug.
          if connection.indexes(referencing_table_name, "#{referencing_table_name} Indexes").any?{|index| index.unique && index.columns == [column_name]}
            macro = :has_one
            name = has_one
            name_concise = has_one_concise
          else
            macro = :has_many
            name = has_many
            name_concise = has_many_concise
            if connection.columns(referencing_table_name, "#{referencing_table_name} Columns").any?{ |col| col.name == 'position' }
              opts[:order] = :position
            end
          end
        end
        name = name_concise if _use_concise_name?
        name = name.to_sym
        if (_filter_association(macro, name) && !_method_exists?(name))
          logger.info "ActiveSchema associations: #{self.name || self.table_name.classify}.#{macro} #{name.inspect}, #{opts.inspect[1...-1]}"
          send macro, name, opts.dup
        end
      end

      def _concise_name(string, other)
        case
        when string =~ /^#{other}_(.*)$/           then $1
        when string =~ /(.*)_#{other}$/            then $1
        when leader = _common_leader(string,other) then string[leader.length, string.length-leader.length]
        else                                            string
        end
      end

      def _common_leader(string, other)
        leader = nil
        other.split('_').each do |part|
          test = "#{leader}#{part}_"
          break unless string.start_with? test
          leader = test
        end
        return leader
      end

      def _use_concise_name?
        active_schema_config.associations.concise_names?
      end

      def _filter_association(macro, name)
        config = active_schema_config.associations
        case
        when config.only        then Array.wrap(config.only).include?(name)
        when config.except      then !Array.wrap(config.except).include?(name)
        when config.only_type   then Array.wrap(config.only_type).include?(macro)
        when config.except_type then !Array.wrap(config.except_type).include?(macro)
        else true
        end
      end

      def _method_exists?(name)
        method_defined?(name) || private_method_defined?(name) and not (name == :type && [Object, Kernel].include?(instance_method(:type).owner))
      end

    end
  end
end