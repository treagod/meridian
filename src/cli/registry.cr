module Meridian
  module CLI
    class Registry
      getter commands : Array(Command.class)

      def initialize(@commands : Array(Command.class))
      end

      def resolve(args : Array(String)) : {Command.class, Array(String)}?
        sorted = @commands.sort_by { |klass| -klass.new.name.count(' ') }

        sorted.each do |klass|
          tokens = klass.new.name.split(' ')
          next if args.size < tokens.size
          next unless args[0, tokens.size] == tokens

          return {klass, args[tokens.size..]}
        end

        nil
      end

      def top_level : Array(Command.class)
        @commands.select { |klass| !klass.new.name.includes?(' ') }
      end
    end
  end
end
