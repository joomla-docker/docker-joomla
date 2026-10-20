# Exact release versions and explicit aliases own the tags. Directory names do
# not introduce aliases; prereleases cannot acquire stable tags by truncation.
def require($condition; $message):
  if $condition then . else error($message) end;

def valid_tag:
  type == "string" and test("^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$");

def unique_ordered:
  reduce .[] as $item ([]; if index($item) == null then . + [$item] else . end);

def release_aliases($series; $state; $release):
  $release
  | require(.version | type == "string"; "\($series)/\($state): version must be a string")
  | (.version | (try capture("^(?<series>[0-9]+\\.[0-9]+)\\.[0-9]+(?:-(?<state>alpha|beta|rc)[1-9][0-9]*)?$") catch null) // null) as $parsed
  | require($parsed != null and $parsed.series == $series and ($parsed.state // "stable") == $state;
      "\($series)/\($state): version does not match its series and state")
  | (if .aliases == null then [] else .aliases end) as $aliases
  | require($aliases | type == "array"; "\($series)/\($state): aliases must be an array")
  | require(all($aliases[]; type == "string" or type == "number");
      "\($series)/\($state): aliases must contain strings or numbers")
  | ([$release.version] + ($aliases | map(tostring)) | unique_ordered) as $names
  | require(all($names[]; valid_tag and . != "dev" and (endswith("-dev") | not)
      and (. == "latest" or (contains("latest") | not)));
      "\($series)/\($state): invalid or reserved release alias")
  | require($state == "stable" or all($names[];
      . == $state or test("-" + $state + "[0-9]*$"));
      "\($series)/\($state): prerelease aliases must retain their release state")
  | $names;

def suffix($ending):
  map(if . == "latest" then $ending else . + "-" + $ending end);

def context_tags($names; $php; $variant; $is_default):
  ($names | suffix("php" + $php)) as $php_names
  | (if $is_default then $names + ($names | suffix($variant)) + $php_names else [] end)
    + ($php_names | map(. + "-" + $variant))
  | unique_ordered;

require(type == "object" and length > 0; "conf/versions.json must contain configured release series")
| . as $configuration
| [
    (keys | sort_by(split(".") | map(tonumber)) | reverse[]) as $series
    | $configuration[$series] as $settings
    | require($settings.phpVersions | type == "object" and length > 0;
        "\($series): phpVersions must be a nonempty object")
    | require($settings.variants | type == "array" and length > 0;
        "\($series): variants must be a nonempty array")
    | require($settings.variant | type == "string";
        "\($series): default variant must be a string")
    | require(($settings.variants | index($settings.variant)) != null;
        "\($series): default variant must be configured")
    | require(($settings | has("php") or has("packageType")) | not;
        "\($series): php and packageType belong in each release state")
    | require($settings.states | type == "object" and length > 0;
        "\($series): states must be a nonempty object")
    | require(all($settings.states | keys[]; . == "stable" or . == "alpha" or . == "beta" or . == "rc");
        "\($series): unsupported release state")
    | ["stable", "alpha", "beta", "rc"][] as $state
    | select($settings.states | has($state))
    | $settings.states[$state] as $release
    | require($release.php | type == "string"; "\($series)/\($state): php must be a string")
    | require($settings.phpVersions | has($release.php); "\($series)/\($state): default PHP must be configured")
    | release_aliases($series; $state; $release) as $names
    | ($settings.phpVersions | keys | sort_by(split(".") | map(tonumber))[]) as $php
    | $settings.variants[] as $variant
    | require($php | test("^[0-9]+\\.[0-9]+$"); "\($series): invalid PHP version")
    | require($variant == "apache" or $variant == "fpm" or $variant == "fpm-alpine";
        "\($series): unsupported runtime variant")
    | context_tags($names; $php; $variant; $php == $release.php and $variant == $settings.variant) as $tags
    | (if ($settings.phpVersions[$php].dev // null) == null then [false] else [false, true] end)[] as $development
    | {
        series: $series,
        state: $state,
        version: $release.version,
        php: $php,
        variant: $variant,
        development: $development,
        directory: ("images/\($series)/\($state)/php\($php)/\($variant)" + (if $development then "-dev" else "" end)),
        tags: (if $development then $tags | map(if . == "latest" then "dev" else . + "-dev" end) else $tags end)
      }
  ]
| require(all(.[] | .tags[]; valid_tag); "an expanded image tag is invalid or longer than 128 characters")
| . as $contexts
| ([.[] | .directory as $directory | .tags[] | {tag: ., directory: $directory}]
    | group_by(.tag) | map(select(length > 1))) as $collisions
| require($collisions | length == 0;
    "tag collision: " + ($collisions | map(.[0].tag + " -> " + (map(.directory) | join(", "))) | join("; ")))
| $contexts
