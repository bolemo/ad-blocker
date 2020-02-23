#!/bin/sh
###########################
# (C) 2017 Steven Black
###########################
#
# 2017-04-17 - 1.0.0 Initial release 2017-04-18 - 1.1.0 Improved modularization; added functionality for white & 
# black lists 2017-04-25 - 1.1.1 Relocated conf dir to /usr/local/etc 2017-04-25 - 1.1.2 Relocate script dir; 
# update checks to create conf templates 2017-05-17 - 1.1.3 Remove local declarations for improved compatibility 
# 2017-05-17 - 1.1.4 Cleanup syntax as per shellcheck.net suggestions
# 2020-02-23 - 1.1.5 Allow to set blacklist(s) from a conf file

###########################

# routine for ensuring all necessary dependencies are found
check_deps () {
  Deps="date grep mv rm sed wget whoami su"
  MissingDeps=0

  for NeededDep in $Deps; do
    if ! hash "$NeededDep" > /dev/null 2>&1; then
      printf "Command not found in PATH: %s\n" "$NeededDep" >&2
      MissingDeps=$((MissingDeps+1))
    fi
  done
  if [ $MissingDeps -gt 0 ]; then
    printf "%d commands not found in PATH; aborting\n" "$MissingDeps" >&2
    exit 1
  fi
}

# check for whitelist/blacklist configuration files & create templates if not present
check_conf () {
  ServerList="${ConfDir}/ad-blocker-sl.conf"
  WhiteList="${ConfDir}/ad-blocker-wl.conf"
  BlackList="${ConfDir}/ad-blocker-bl.conf"

  # if no ServerList found, then create a template & instructions
  if [ ! -f "$ServerList" ]; then
    echo "No server list found; creating template" >&2
    { echo "# List of blocklists urls for ad-blocker.sh";
      echo "# The blocklists must just be one domain name per line (no Bind or Hosts format)";
      echo "# Add one blocklist url per line";
      echo "# Comments are indicated by a '#' as the first character";
      echo "https://pgl.yoyo.org/as/serverlist.php?hostformat=list&showintro=0&mimetype=plaintext";
      echo "https://v.firebog.net/hosts/Easylist.txt";
      echo "https://gist.githubusercontent.com/BBcan177/b96dd281c5acd5327825a22c63f9f9c9/raw/94c1585a189347e35c0070a9e4de76fde2adb271/liste_fr.txt";
      echo "https://raw.githubusercontent.com/deathbybandaid/piholeparser/master/Subscribable-Lists/CountryCodesLists/France.txt";
    } > "$ServerList"
  fi

  # if no white list found, then create a template & instructions
  if [ ! -f "$WhiteList" ]; then
    echo "No white list found; creating template" >&2
    { echo "# White list of domains to remain unblocked for ad-blocker.sh";
      echo "# Add one fully-qualified domain name per line";
      echo "# Comments are indicated by a '#' as the first character";
      echo "# example:";
      echo "# ad.example.com";
    } > "$WhiteList"
  fi

  # if no black list found, then create a template & instructions
  if [ ! -f "$BlackList" ]; then
    echo "No black list found; creating template" >&2
    { echo "# Black list of additional domains for ad-blocker.sh";
      echo "# Add one fully-qualified domain name per line";
      echo "# Comments are indicted by a '#' as the first character";
      echo "# example:";
      echo "# ad.example.com";
    } > "$BlackList"
  fi
}

# verify running as proper user if not, attempt to switch and abort if cannot
check_user () {
  User=$(whoami)
  if [ "$User" != "DNSServer" ]; then
    echo "Running as $User; switching to DNSServer" >&2
    su -m DNSServer "$0" "$@" || exit 1
    exit 0
  fi
}

# user-specified list of domains to remain unblocked
apply_whitelist () {
  WhiteList="${ConfDir}/ad-blocker-wl.conf"

  # skip if the config doesn't exist
  if [ ! -f "$WhiteList" ]; then
    return 0
  fi

  # process the whitelist skipping over any comment lines
  while read -r Line; do
    # strip the line if it starts with a '#' if the line was stripped, then continue on to the next line
    Domain=$(echo "$Line" | grep -v "^[[:space:]*\#]")
    if [ -z "$Domain" ]; then
      continue;
    fi

    sed -i "/^$Domain$/d" "$TempNewFile"
  done < "$WhiteList"
  echo "Applied Whitelist"
}

# make sure the include statement is added to the ZoneDataFile
update_zone_data () {
  ZoneDataFile="${ZoneDataDir}/null.zone.file"
  ZoneDataDB="${ZoneDataDir}/ad-blocker.db"

  # move the final version of the block list to the final location
  mv "$TempNewFile" "$ZoneDataDB"

  # safety check: make sure both files exist before proceeding check for the include statement in the
  # ZoneDataFile if it is present do nothing, else append the include statement to the ZoneDataFile
  if [ -f "$ZoneDataDB" ] && [ -f "$ZoneDataFile" ]; then
    Matches=$(grep 'include "/etc/zone/data/ad-blocker.db";' "$ZoneDataFile")
    if [ -z "$Matches" ]; then
      echo '' >> "$ZoneDataFile"
      echo 'include "/etc/zone/data/ad-blocker.db";' >> "$ZoneDataFile"
    fi
  fi
}

# update the ZoneMasterFile with an new serial number
update_zone_master () {
  Now=$(date +"%Y%m%d")
  ZoneMasterFile="${ZoneMasterDir}/null.zone.file"

  if [ -f "$ZoneMasterFile" ]; then
    rm -f "$ZoneMasterFile"
  fi

  # rebuild the zone master file with the updated serial number
  { echo '$TTL 86400 ; one day';
    echo '@ IN SOA ns.null.zone.file. mail.null.zone.file. (';
    echo ' '${Now}'00 ; serial number YYYYMMDDNN';
    echo ' 86400 ; refresh 1 day';
    echo ' 7200 ; retry 2 hours';
    echo ' 864000 ; expire 10 days';
    echo ' 86400 ) ; min ttl 1 day';
    echo ' IN NS ns.null.zone.file.';
    echo ' IN A 127.0.0.1';
    echo '* IN A 127.0.0.1'; } > "$ZoneMasterFile"

  # reload the server config to pick up the changes
  "${RootDir}"/script/reload.sh
}

fetch_blocklists () {
  ServerList="${ConfDir}/ad-blocker-sl.conf"
  while IFS= read -r Line; do
    BlocklistURL=$(echo "$Line" | grep -v "^[[:space:]*\#]")
    if [ -z "$BlocklistURL" ]; then
      continue;
    fi
    wget -O- "$BlocklistURL" | sed -e '/^\s*#.*$/d' -e '/^\s*$/d' >> "$TempWorkFile"
  done < "$ServerList"
  mv "$TempWorkFile" "$TempNewFile"
  echo "Downloaded lists from servers in conf"
}

apply_blacklist () {
  BlackList="${ConfDir}/ad-blocker-bl.conf"

  # skip if the config doesn't exist
  if [ ! -f "$BlackList" ]; then
    return 0;
  fi

  sed -e '/^\s*#.*$/d' -e '/^\s*$/d' "$BlackList" >> "$TempNewFile"
  echo "Added hosts from blacklist"
}

remove_duplicates () {
  sort "$TempNewFile" | uniq > "$TempWorkFile"
  mv "$TempWorkFile" "$TempNewFile"
  echo "Duplicate entries were removed"
}

apply_bind_format () {
  i=0
  while IFS= read -r Domain; do
    echo "zone \"$Domain\" { type master; notify no; file \"/etc/zone/master/null.zone.file\"; };" >> "$TempWorkFile"
    i=$((i+1))
  done < "$TempNewFile"
  mv "$TempWorkFile" "$TempNewFile"
  echo "Applied the BIND format to $i domains"
}

# Global vars for common paths
TempDir="/tmp"
TempWorkFile="${TempDir}/ad-blocker-workfile.tmp"
TempNewFile="${TempDir}/ad-blocker-blocklist.new"
ConfDir="/usr/local/etc"
RootDir="/var/packages/DNSServer/target"
ZoneDir="${RootDir}/named/etc/zone"
ZoneDataDir="${ZoneDir}/data"
ZoneMasterDir="${ZoneDir}/master"

# Main Routine
check_deps
check_conf
check_user "$@"
fetch_blocklists
apply_blacklist
remove_duplicates
apply_whitelist
apply_bind_format
update_zone_data
update_zone_master
exit 0
