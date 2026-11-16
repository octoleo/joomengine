#!/usr/bin/env bash
# Normalize and validate the JSON image matrix without network or file writes.
# Output: an object keyed by target ID, containing enabled targets only.

build_targets_normalize() {
	local versions_file="${1:-}" build_file="${2:-}"
	[[ -f "$versions_file" && -f "$build_file" ]] || {
		printf '[ERROR] Build targets require versions and build JSON files.\n' >&2
		return 2
	}
	if ! jq -e --slurpfile build "$build_file" '
		def nonempty: type == "string" and length > 0;
		def release: type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+(-(alpha|beta|rc)[1-9][0-9]*)?$");
		def jcb_release: type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+(-(alpha|beta|rc)[0-9]*)?$");
		def unique_array: type == "array" and length > 0 and length == (unique | length);
		def known_keys($allowed): (keys - $allowed | length) == 0;
		if type != "object" or length == 0 then error("Image matrix must be a nonempty object") else . end |
		with_entries(
			.key as $id |
			if (.value | type) != "object" then error("Target " + $id + " must be an object") else . end |
			.value |= (
				{enabled:true, channel:"stable", update:"stable", tags:"default", profiles:["standard"]} + . |
				.jcb = ({major:$id, versions:"all"} + (.jcb // {}))
			)
		) |
		if all(to_entries[];
			.key as $id | .value as $target |
			($id | test("^[A-Za-z0-9][A-Za-z0-9_-]*$")) and
			($target | known_keys(["enabled","joomla","channel","update","tags","jcb","php","variants","profiles"])) and
			($target.enabled | type == "boolean") and
			($target.joomla | release) and
			($target.channel | . == "stable" or . == "alpha" or . == "beta" or . == "rc") and
			(if $target.channel == "stable" then
				($target.joomla | test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))
			else ($target.joomla | test("-" + $target.channel + "[1-9][0-9]*$")) end) and
			($target.update == "pinned" or ($target.update == "stable" and $target.channel == "stable")) and
			($target.tags == "qualified" or ($target.tags == "default" and $target.channel == "stable")) and
			($target.jcb | type == "object" and known_keys(["major","versions"])) and
			($target.jcb.major | type == "string" and test("^[1-9][0-9]*$")) and
			($target.jcb.versions |
				. == "all" or . == "latest-stable" or . == "latest-alpha" or . == "latest-beta" or . == "latest-rc" or
				(unique_array and all(.[]; jcb_release and startswith($target.jcb.major + ".")))) and
			($target.php | unique_array and all(.[]; type == "string" and test("^[0-9]+\\.[0-9]+$"))) and
			($target.variants | unique_array and all(.[]; . == "apache" or . == "fpm" or . == "fpm-alpine")) and
			($target.profiles | unique_array and all(.[]; type == "string" and $build[0].profiles[.] != null)) and
			(if $target.enabled then ($build[0].sources.jcb_updates[$target.jcb.major] | nonempty) else true end)
		) then . else error("Invalid target: check release channels, JCB selectors, update policy, tag policy, PHP, variants and profiles") end |
		with_entries(select(.value.enabled)) |
		if length == 0 then error("At least one build target must be enabled") else . end |
		([.[] | select(.tags == "default") | .jcb.major]) as $default_majors |
		if ($default_majors | length) == ($default_majors | unique | length) then .
		else error("Only one default-tag target is allowed per JCB major; use qualified tags for additional targets") end
	' "$versions_file"; then
		printf '[ERROR] Invalid JSON build-target configuration: %s\n' "$versions_file" >&2
		return 2
	fi
}
