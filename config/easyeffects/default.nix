{ config, pkgs, ... }:

{
	home.file.".config/easyeffects/input/filter.json".source = ./input/filter.json;
}
