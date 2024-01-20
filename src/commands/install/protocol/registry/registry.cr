require "../../resolver"
require "../base"
require "./resolver"

struct Zap::Commands::Install::Protocol::Registry < Zap::Commands::Install::Protocol::Base
  # [<@scope>/]<name>
  # [<@scope>/]<name>@<tag>
  # [<@scope>/]<name>@<version range>
  def self.normalize?(str : String, path_info : PathInfo?) : {String?, String?}?
    parts = str.split('@')
    if parts.size == 1 || (parts.size == 2 && str.starts_with?('@'))
      return nil, str
    else
      return parts.last, parts[...-1].join('@')
    end
  end

  def self.resolver?(
    state,
    name,
    specifier = "latest",
    parent = nil,
    dependency_type = nil,
    skip_cache = false
  ) : Protocol::Resolver?
    Log.debug { "(#{name}@#{specifier}) Resolved as a registry dependency" }
    semver = Utils::Semver.parse?(specifier)
    Log.debug { "(#{name}@#{specifier}) Failed to parse semver '#{specifier}', treating as a dist-tag." } unless semver
    Resolver.new(state, name, semver || specifier, parent, dependency_type, skip_cache)
  end
end
