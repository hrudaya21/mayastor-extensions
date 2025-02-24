# It would be cool to produce OCI images instead of docker images to
# avoid dependency on docker tool chain. Though the maturity of OCI
# builder in nixpkgs is questionable which is why we postpone this step.

{ dockerTools, lib, extensions, busybox, gnupg, kubernetes-helm-wrapped, semver-tool, yq-go, runCommand, img_tag ? "" }:
let
  whitelistSource = extensions.project-builder.whitelistSource;
  helm_chart = whitelistSource ../../.. [ "chart" "scripts/helm" ] "mayastor-extensions";
  image_suffix = { "release" = ""; "debug" = "-debug"; "coverage" = "-coverage"; };
  tag = if img_tag != "" then img_tag else extensions.version;
  build-extensions-image = { pname, buildType, package, extraCommands ? '''', copyToRoot ? [ ], config ? { } }:
    dockerTools.buildImage {
      inherit extraCommands tag;
      created = "now";
      name = "openebs/mayastor-${pname}${image_suffix.${buildType}}";
      copyToRoot = [ package ] ++ copyToRoot;
      config = {
        Entrypoint = [ package.binary ];
      } // config;
    };
  build-exporter-image = { buildType }: {
    io-engine = build-extensions-image rec{
      inherit buildType;
      package = extensions.${buildType}.metrics.exporter.io-engine;
      pname = package.pname;
      config = {
        ExposedPorts = {
          "9052/tcp" = { };
        };
      };
    };
  };
  tagged_helm_chart = runCommand "tagged_helm_chart"
    {
      nativeBuildInputs = [ kubernetes-helm-wrapped helm_chart semver-tool yq-go ];
    } ''
    mkdir -p build && cp -drf ${helm_chart}/* build

    chmod +w build/scripts/helm
    chmod +w build/chart
    chmod +w build/chart/*.yaml
    patchShebangs build/scripts/helm/publish-chart-yaml.sh

    # if tag is not semver just keep whatever is checked-in
    # todo: handle this properly?
    # Script doesn't need to be used with main branch `--alias-tag <main-branch-style-tag>`.
    # The repo chart is already prepared.
    if [[ "$(semver validate ${tag})" == "valid" ]] &&
      [[ ! ${tag} =~ ^(v?[0-9]+\.[0-9]+\.[0-9]+-0-main-unstable(-[0-9]+){6}-0)$ ]]; then
      CHART_FILE=build/chart/Chart.yaml build/scripts/helm/publish-chart-yaml.sh --app-tag ${tag} --override-index ""
    fi
    chmod -w build/chart
    chmod -w build/chart/*.yaml

    mkdir -p $out && cp -drf --preserve=mode build/chart $out/chart
  '';
  build-upgrade-image = { buildType, name }:
    build-extensions-image rec{
      inherit buildType;
      package = extensions.${buildType}.upgrade.${name};
      copyToRoot = [ kubernetes-helm-wrapped busybox tagged_helm_chart yq-go ];
      pname = package.pname;
      config = {
        Env = [ "CORE_CHART_DIR=/chart" ];
      };
    };
  build-obs-callhome-image = { buildType }:
    build-extensions-image rec{
      inherit buildType;
      package = extensions.${buildType}.obs.callhome;
      copyToRoot = [ ./../../../call-home/assets busybox gnupg ];
      extraCommands = ''
        mkdir -p encryption_dir
      '';
      pname = package.pname;
      config = {
        Env = [ "KEY_FILEPATH=/key/public.gpg" "ENCRYPTION_DIR=/encryption_dir" ];
      };
    };

  build-obs-callhome-stats-image = { buildType }:
    build-extensions-image rec{
      inherit buildType;
      package = extensions.${buildType}.obs.stats;
      pname = package.pname;
      config = {
        ExposedPorts = {
          "9090/tcp" = { };
        };
      };
    };

in
let
  build-exporter-images = { buildType }: {
    exporter = build-exporter-image {
      inherit buildType;
    };
  };
  build-upgrade-images = { buildType }: {
    job = build-upgrade-image {
      inherit buildType;
      name = "job";
    };
  };
  build-obs-images = { buildType }: {
    callhome = build-obs-callhome-image {
      inherit buildType;
    };
  };
  build-stats-images = { buildType }: {
    aggregator = build-obs-callhome-stats-image {
      inherit buildType;
    };
  };
in
let
  build-images = { buildType }: {
    metrics = build-exporter-images { inherit buildType; } // {
      recurseForDerivations = true;
    };
    upgrade = build-upgrade-images { inherit buildType; } // {
      recurseForDerivations = true;
    };
    obs = build-obs-images { inherit buildType; } // {
      recurseForDerivations = true;
    };
    stats = build-stats-images { inherit buildType; } // {
      recurseForDerivations = true;
    };
  };
in
{
  release = build-images { buildType = "release"; };
  debug = build-images { buildType = "debug"; };
}
