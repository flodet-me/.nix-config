{
  config,
  inputs,
  pkgs,
  ...
}:
{
  environment.etc."blocky/config.yml".source = ./config.yml;

  virtualisation.oci-containers = {
    backend = "docker";
    containers = {
      blocky = {
        image = "spx01/blocky:latest";
        ports = [
          "53:53/tcp"
          "53:53/udp"
        ];
        environment = {
          TZ = "Europe/Berlin";
        };
        volumes = [
          "/etc/blocky/config.yml:/app/config.yml"
        ];
      };
    };
  };

}
