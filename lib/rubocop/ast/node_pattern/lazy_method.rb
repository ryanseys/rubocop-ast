# frozen_string_literal: true

module RuboCop
  module AST
    class NodePattern
      # Defines the method of `def_node_matcher` or `def_node_search` as a
      # stub that compiles the pattern on its first call. Compiling a pattern
      # is slow, and most patterns are never used in a given run.
      #
      # The first call puts the compiled method in place of the stub, so
      # later calls go directly to it. Aliases and `module_function` copies
      # of the stub keep calling the stub, which forwards to that method.
      # @api private
      class LazyMethod
        LOCK = Mutex.new
        private_constant :LOCK

        # Keyword defaults wrap the method in a second one, and names such as
        # `self.foo` define a singleton method, so these compile at once.
        # Setting the `RUBOCOP_AST_EAGER_NODE_PATTERNS` environment variable
        # compiles all patterns at once, for example to make a test suite
        # report invalid patterns when it loads them.
        def self.applies_to?(method_name, keyword_defaults)
          keyword_defaults.empty? && !method_name.to_s.include?('.') &&
            !ENV.fetch('RUBOCOP_AST_EAGER_NODE_PATTERNS', false)
        end

        # The block returns the source of the method.
        # `location` is where the method is attributed to, as for eager methods.
        def self.define(base, method_name, location, &source)
          new(base, method_name, location, source).define
        end

        def initialize(base, method_name, location, source)
          @base = base
          @method_name = method_name
          @location = location
          @source = source
        end

        def define
          lazy_method = self
          @base.define_method(@method_name) do |*args, **kwargs, &block|
            lazy_method.compiled.bind_call(self, *args, **kwargs, &block)
          end
          @stub = @base.instance_method(@method_name)
          @method_name
        end

        def compiled
          @compiled || LOCK.synchronize { @compiled ||= compile }
        end

        private

        def compile
          source = @source.call
          # If a later definition replaced the stub, which an alias can still
          # call, keep that definition and put the compiled method in a
          # module of its own. Do the same if the class is frozen.
          return compile_into(Module.new, source) unless stub_in_place?

          visibility = stub_visibility
          # Aliasing the stub to itself silences the "method redefined" warning.
          @base.alias_method(@method_name, @method_name)
          compiled = compile_into(@base, source)
          @base.send(visibility, @method_name)
          compiled
        end

        def stub_in_place?
          !@base.frozen? && @base.instance_method(@method_name) == @stub
        rescue NameError
          false
        end

        def stub_visibility
          if @base.private_method_defined?(@method_name, false)
            :private
          elsif @base.protected_method_defined?(@method_name, false)
            :protected
          else
            :public
          end
        end

        def compile_into(owner, source)
          owner.class_eval(source, @location.path, @location.lineno)
          owner.instance_method(@method_name)
        end
      end
    end
  end
end
