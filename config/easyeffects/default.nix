{ config, pkgs, ... }:

{
  # Input filter for easyeffects
  # Source: https://gist.github.com/jtrv/47542c8be6345951802eebcf9dc7da31
	home.file.".config/easyeffects/input/filter.json".source = ./input/filter.json;

  # Output filter for easyeffects
  # Source: https://github.com/JackHack96/EasyEffects-Presets
  home.file.".config/easyeffects/output/Advanced_Auto_Gain.json".source = ./output/Advanced_Auto_Gain.json;
  home.file.".config/easyeffects/output/Bass_Boosted.json".source = ./output/Bass_Boosted.json;
  home.file.".config/easyeffects/output/Bass_Enhancing+Perfect_EQ.json".source = ./output/Bass_Enhancing+Perfect_EQ.json;
  home.file.".config/easyeffects/output/Boosted.json".source = ./output/Boosted.json;
  home.file.".config/easyeffects/output/Loudness+Autogain.json".source = ./output/Loudness+Autogain.json;
  home.file.".config/easyeffects/output/Perfect_EQ.json".source = ./output/Perfect_EQ.json;

  # Source: https://github.com/p-chan5/EasyPulse
  home.file.".config/easyeffects/output/edm.json".source = ./output/edm.json;
  home.file.".config/easyeffects/output/hifi.json".source = ./output/hifi.json;
  home.file.".config/easyeffects/output/indie.json".source = ./output/indie.json;
  home.file.".config/easyeffects/output/kpop.json".source = ./output/kpop.json;
  home.file.".config/easyeffects/output/lofi.json".source = ./output/lofi.json;
  home.file.".config/easyeffects/output/rock.json".source = ./output/rock.json;
  home.file.".config/easyeffects/output/classical.json".source = ./output/classical.json;

}
