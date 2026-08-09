{pkgs, config, lib, ...}:
let
  # Claude Code's plugin marketplace machinery can emit SSH URLs for a `github`
  # source, and not every machine has a GitHub SSH key. These three repos are
  # public, so rewriting them to HTTPS lets the plugins clone with no auth at
  # all.
  #
  # Scoped per repo, deliberately. A namespace-wide `git@github.com:peterstorm/`
  # rewrite also captures the *private* repos in that namespace (the Obsidian
  # vault, this dotfiles repo), redirecting their authenticated SSH remotes to
  # an HTTPS endpoint where no credential helper is configured. Interactive git
  # then prompts for a username; non-interactive git (systemd timers) just dies
  # with "could not read Username for 'https://github.com'".
  #
  # Matching is by URL prefix, so each entry also covers `<repo>.git` and any
  # repo whose name extends it (e.g. loom -> loom-tui) — all public, all fine.
  publicPluginRepos = [ "loom" "cortex" "feynman" ];

  pluginUrlRewrites = lib.listToAttrs (map (repo: {
    name = "https://github.com/peterstorm/${repo}";
    value.insteadOf = "git@github.com:peterstorm/${repo}";
  }) publicPluginRepos);
in
{

  programs.git = {
    enable = true;
    settings = {
      user = {
        name = "Peter Storm";
        email = "peter.storm@peterstorm.io";
      };
      init = {
        defaultBranch = "main";
      };
      url = pluginUrlRewrites;
    };
  };
}
