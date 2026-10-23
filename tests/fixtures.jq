# Tests use the resolved configuration; synthetic releases cover missing release states.
.
| if $fixture == "current" then .
  elif $fixture == "synthetic" then
    (to_entries[0].value.states | to_entries[0].value.php) as $php
    | (to_entries[0].value.states | to_entries[0].value.variant) as $variant
    | (to_entries[0].value
      | .states = {
          stable: {version: "100.0.0", aliases: ["100.0", "100", "latest"]},
          alpha: {version: "100.0.1-alpha1", aliases: ["100.0-alpha"]},
          beta: {version: "100.0.1-beta1", aliases: ["100.0-beta"]},
          rc: {version: "100.0.1-rc1", aliases: ["100.0-rc"]}}) as $seed
    | {"100.0": $seed, "101.0": ($seed | .states = {alpha: {version:"101.0.0-alpha1", aliases:[]}})}
    | map_values(.states |= map_values(. + {php:$php, variant:$variant, packageType:"tar.zst",
        package:("https://example.invalid/" + .version + ".tar.zst"), sha512:("0" * 128)}))
  else error("unknown fixture") end
