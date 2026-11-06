#!/usr/bin/env bash
# Jupiter installer - timezone lookup, driven by the system zone.tab.

ZONE_TAB="${ZONE_TAB:-/usr/share/zoneinfo/zone.tab}"

# tz_regions - "UTC" followed by every top-level region, sorted.
tz_regions() {
    printf 'UTC\n'
    awk -F'\t' '!/^#/ && NF >= 3 {
            if (split($3, part, "/") > 1) print part[1]
        }' "${ZONE_TAB}" | sort -u
}

# tz_cities REGION - print "zone|description" for a region.
tz_cities() {
    awk -F'\t' -v region="$1" '!/^#/ && NF >= 3 {
            if (split($3, part, "/") > 1 && part[1] == region) {
                description = (NF >= 4 ? $4 : "")
                if (description == "") description = $1
                printf "%s|%s\n", $3, description
            }
        }' "${ZONE_TAB}" | sort -t'|' -k1,1 -u
}

# tz_country ZONE - the ISO 3166 country code zone.tab records for a zone.
# Used to suggest a language and keyboard layout; empty for zones that have
# no country (UTC).
tz_country() {
    awk -F'\t' -v zone="$1" '!/^#/ && NF >= 3 && $3 == zone { print $1; exit }' "${ZONE_TAB}"
}
