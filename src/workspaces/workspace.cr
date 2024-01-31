require "../package"

class Zap::Workspaces
  record Workspace, package : Package, path : Path, relative_path : Path do
    def matches?(filter : Workspaces::Filter, diffs : Diffs? = nil)
      matches = true
      if scope = filter.scope
        matches &&= File.match?(scope, package.name)
      end
      if glob = filter.glob
        matches &&= File.match?(glob, relative_path)
      end
      if since = filter.since
        matches &&= diffs.try &.get(path.to_s, since).any? do |diff|
          diff.starts_with?(relative_path.to_s)
        end
      end
      matches
    end
  end
end
