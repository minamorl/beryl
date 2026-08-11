# frozen_string_literal: true

module Berylx
  class Focus
    MISSING = Object.new.freeze

    def self.[](value = {})
      new(value)
    end

    attr_reader :value, :path

    # 格納する値は深く凍結する (Berylx::Freeze の不変条件)。未凍結の入力は
    # 複製してから凍結するので、呼び出し側のデータはそのまま可変で残る。
    def initialize(value = {}, path = [])
      @value = Freeze.deep(value)
      @path = path.freeze
    end

    # 焦点の移動は凍結済みの @value をそのまま共有する。new を通すと
    # Freeze.deep が木全体を再走査してしまうので、path だけ差し替える —
    # 移動のコストは path 長に比例し、状態の大きさに比例しない。
    def [](key)
      child = dup
      child.refocus!(@path + [key])
      child
    end

    def get(default: MISSING)
      dig(@value, @path)
    rescue KeyError, NoMethodError => e
      return default unless default.equal?(MISSING)

      raise e
    end

    def fetch(default = MISSING)
      get(default: default)
    end

    def maybe
      get(default: nil)
    end

    def present?
      dig(@value, @path)
      true
    rescue KeyError, NoMethodError
      false
    end

    def required(code = :missing_focus, message = nil)
      get
      Result.ok(self)
    rescue KeyError, NoMethodError => e
      reject(code, message || "missing focus at #{path.inspect}", cause: e)
    end

    def set(next_value)
      self.class.new(assoc_in(@value, @path, next_value))
    end

    def update(&block)
      set(block.call(get))
    end

    def put(key, next_value)
      self[key].set(next_value)
    end

    def reject(code, message = code.to_s, cause: nil)
      Result.err(self, code, message, cause: cause)
    end

    def to_h
      @value
    end

    def inspect
      "#<Berylx::Focus path=#{@path.inspect} value=#{get.inspect}>"
    end

    protected

    def refocus!(path)
      @path = path.freeze
    end

    private

    def dig(current, path)
      path.reduce(current) do |acc, key|
        case acc
        when Hash
          acc.fetch(key)
        else
          acc.public_send(key)
        end
      end
    end

    def assoc_in(current, path, next_value)
      return next_value if path.empty?

      key = path.fetch(0)
      rest = path.drop(1)

      case current
      when Hash
        current.merge(key => assoc_in(current.fetch(key, nil), rest, next_value))
      else
        raise TypeError, "cannot update #{current.class} at #{key.inspect}" unless current.respond_to?(:with)

        current.with(key => assoc_in(current.public_send(key), rest, next_value))

      end
    end
  end
end
