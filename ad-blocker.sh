#!/bin/bash
###########################
# (C) 2020 bOLEMO
# based on the original ad-blockerscript for Synology by Steven Black
# inspired by -Setting up a DNS Firewall on steroids- by NavyTitanium
###########################
#
# 2017-04-17 - 1.x.x Initial Adblock script by Steven Black
# 2020-02-23 - 1.1.5 Allow to set blacklist(s) from a conf file
# 2020-03-10 - 2.0.0 Now using RPZ

###########################

# routine for ensuring all necessary dependencies are found
check_deps () {
  DEPS="date grep mv rm sed wget whoami su sort uniq wc"
  MISSING_DEPS=0

  for NEEDED_DEP in $DEPS; do
    if ! hash "$NEEDED_DEP" > /dev/null 2>&1; then
      printf "Command not found in PATH: %s\n" "$NEEDED_DEP" >&2
      MISSING_DEPS=$((MISSING_DEPS+1))
    fi
  done
  if [ $MISSING_DEPS -gt 0 ]; then
    printf "%d commands not found in PATH; aborting\n" "$MISSING_DEPS" >&2
    exit 1
  fi
}

# verify running as proper user if not, attempt to switch and abort if cannot
check_user () {
  USER=$(whoami)
  if [ "$USER" != "DNSServer" ]; then
    echo "Running as user $USER; switching to user DNSServer" >&2
    su -m DNSServer "$0" "$@" || exit 1
    exit 0
  fi
}

# check for configuration files & create files / templates if not present
check_conf () {
  # check zone.load.conf
  echo 'Looking up zone.load.conf file...' >&2
  if [ -f "$NAMED_ZONE_LOAD_CFG_FILE" ]; then
    echo ' - File found' >&2
    # check if file includes RPZ Blocklist
    if grep -q "include[[:space:]]*\"/etc/zone/data/${RPZ_BLOCKLIST_NAME//./\.}\"" "$NAMED_ZONE_LOAD_CFG_FILE"; then
      echo ' - Loader includes RPZ Blocklist' >&2
    else
      echo " ! Zone $RPZ_BLOCKLIST_NAME is missing! Exiting" >&2
      exit 1
    fi
    # check if file includes Sinkhole Zone
    if grep -q "include[[:space:]]*\"/etc/zone/data/${SINKHOLE_ZONE_NAME//./\.}\"" "$NAMED_ZONE_LOAD_CFG_FILE"; then
      echo ' - Loader includes Sinkhole Zone' >&2
    else
      echo " ! Zone $SINKHOLE_ZONE_NAME is missing! Exiting" >&2
      exit 1
    fi
  else
    echo ' ! File is missing! Exiting' >&2
    exit 1
  fi

  # create the RPZ Blocklist Zone File
  [ -f "$RPZ_BLOCKLIST_DEF_FILE" ] && rm -f "$RPZ_BLOCKLIST_DEF_FILE"
  { echo "zone \"$RPZ_BLOCKLIST_NAME\" {";
    echo -e "\ttype master;";
    echo -e "\tfile \"/etc/zone/master/$RPZ_BLOCKLIST_NAME\";";
    echo -e "\tallow-update {none;};";
    echo -e "\tallow-transfer {none;};";
    echo -e "\tallow-query {none;};";
    echo "};";
  } > "$RPZ_BLOCKLIST_DEF_FILE"

  # make sure the BIND user conf has a response-policy section with the RPZ blocklist Zone
  echo 'Looking up BIND Options User Conf...' >&2
  if [ -f "$NAMED_OPT_USR_CFG_FILE" ]; then
    echo ' - File found' >&2
    if grep -q "response-policy[[:space:]]*{" "$NAMED_OPT_USR_CFG_FILE"; then
      echo ' - Found Response Policy Section' >&2
      if grep -q "zone[[:space:]]*\"${RPZ_BLOCKLIST_NAME//./\.}\";" "$NAMED_OPT_USR_CFG_FILE"; then
        echo ' - Blocklist RPZ is included' >&2
      else
        echo ' ! Blocklist RPZ missing, adding it...' >&2
        sed -i "/response-policy {/ a \\\tzone \"$RPZ_BLOCKLIST_NAME\";" "$NAMED_OPT_USR_CFG_FILE"
        echo ' - Blocklist RPZ added to Response Policy Section' >&2
      fi
    else
      echo ' ! Response Policy Section missing, adding it...' >&2
      { echo "response-policy {";
        echo -e "\tzone \"$RPZ_BLOCKLIST_NAME\";";
        echo "};";
      } >> "$NAMED_OPT_USR_CFG_FILE"
      echo ' - Response Policy Section with Blocklist RPZ added to User Options Conf File' >&2
    fi
  else
    echo ' ! File is missing, creating it with Response Policy Section with Blocklist RPZ' >&2
    { echo "response-policy {";
      echo -e "\tzone \"$RPZ_BLOCKLIST_NAME\";";
      echo "};";
    } > "$NAMED_OPT_USR_CFG_FILE"
  fi

  # if no ServerList found, then create a template & instructions
  if [ ! -f "$SL_CFG_FILE" ]; then
    echo "No server list found; creating template" >&2
    { echo "# List of blocklists urls for ad-blocker.sh";
      echo "# The blocklists must just be one provider URL per line (no Bind or Hosts format)";
      echo "# Comments are indicated by a '#' as the first character";
      echo "https://pgl.yoyo.org/as/serverlist.php?hostformat=list&showintro=0&mimetype=plaintext";
      echo "https://v.firebog.net/hosts/Easylist.txt";
      echo "https://gist.githubusercontent.com/BBcan177/b96dd281c5acd5327825a22c63f9f9c9/raw/94c1585a189347e35c0070a9e4de76fde2adb271/liste_fr.txt";
    } > "$SL_CFG_FILE"
  fi

  # if no whitelist found, then create a template & instructions
  if [ ! -f "$WL_CFG_FILE" ]; then
    echo "No white list found; creating template" >&2
    { echo "# White list of domains or IPs to remain unblocked for ad-blocker.sh";
      echo "# Add one FQDN or IP per line";
      echo "# Comments are indicated by a '#' as the first character";
      echo "# example:";
      echo "# ad.example.com";
    } > "$WL_CFG_FILE"
  fi

  # if no blacklist found, then create a template & instructions
  if [ ! -f "$BL_CFG_FILE" ]; then
    echo "No black list found; creating template" >&2
    { echo "# Black list of additional domains or IPs for ad-blocker.sh";
      echo "# Add one FQDN or IP per line";
      echo "# Comments are indicted by a '#' as the first character";
      echo "# example:";
      echo "# ad.example.com";
    } > "$BL_CFG_FILE"
  fi
}

fetch_blocklists () {
  echo "Fetching block lists from servers in conf" >&2
  while IFS= read -r LINE; do
    BlocklistURL=$(echo "$LINE" | grep -v "^[[:space:]*\#]")
    if [ -z "$BlocklistURL" ]; then
      continue;
    fi
    echo " - Getting list from $BlocklistURL" >&2
    wget -qO- "$BlocklistURL" | sed -e '/^\s*#.*$/d' -e '/^\s*$/d' >> "$TEMP_FILE1"
  done < "$SL_CFG_FILE"
  mv "$TEMP_FILE1" "$TEMP_FILE2"
}

apply_blacklist () {
  # skip if the config doesn't exist
  if [ ! -f "$BL_CFG_FILE" ]; then
    return 0;
  fi

  sed -e '/^\s*#.*$/d' -e '/^\s*$/d' "$BL_CFG_FILE" >> "$TEMP_FILE2"
  echo "Added Entries from User defined Blacklist" >&2
}

remove_duplicates () {
  sort "$TEMP_FILE2" | uniq > "$TEMP_FILE1"
  DUP_COUNT=$(($(wc -l < "$TEMP_FILE2")-$(wc -l < "$TEMP_FILE1")))
  mv "$TEMP_FILE1" "$TEMP_FILE2"
  echo "Removed $DUP_COUNT duplicate entries" >&2
}

# user-specified list of domains to remain unblocked
apply_whitelist () {
  # skip if the config doesn't exist
  if [ ! -f "$WL_CFG_FILE" ]; then
    return 0
  fi

  # process the whitelist skipping over any comment lines
  while read -r LINE; do
    # strip the line if it starts with a '#' if the line was stripped, then continue on to the next line
    ENTRY=$(echo "$LINE" | grep -v "^[[:space:]*\#]")
    if [ -z "$ENTRY" ]; then
      continue;
    fi

    sed -i "/^$ENTRY$/d" "$TEMP_FILE2"
  done < "$WL_CFG_FILE"
  echo "Removed User defined Whitelist entries" >&2
}

build_rpz_zone_file () {
  echo "Building RPZ Blocklist Database..." >&2
  NOW=$(date +"%Y%m%d%H")

  # build the rpz zone file with the updated serial number
  { echo '$TTL 300';
    echo "@ IN SOA localhost. root.localhost. ( ${NOW} 10800 3600 604800 3600 )";
    echo '@ IN NS localhost.'; } > "$TEMP_FILE1"

  # add each domain/ip from blocklist to rpz zone file
  IPCOUNT=0
  DOMCOUNT=0
  while IFS= read -r ENTRY; do
    if [[ $ENTRY =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      # ENTRY is an IPV4 adress
      echo "$ENTRY.ns-ip IN CNAME drop.$SINKHOLE_ZONE_NAME." >> "$TEMP_FILE1"
      IPCOUNT=$((IPCOUNT+1))
    elif [[ $ENTRY =~ ^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$ ]]; then
      # ENTRY is an IPV6 adress
      echo "$ENTRY.ns-ip IN CNAME drop.$SINKHOLE_ZONE_NAME." >> "$TEMP_FILE1"
#!/bin/bash
###########################
# (C) 2020 bOLEMO
# based on the original ad-blockerscript for Synology by Steven Black
# inspired by -Setting up a DNS Firewall on steroids- by NavyTitanium
###########################
#
# 2017-04-17 - 1.x.x Initial Adblock script by Steven Black
# 2020-02-23 - 1.1.5 Allow to set blacklist(s) from a conf file
# 2020-03-10 - 2.0.0 Now using RPZ
# 2020-03-15 - 2.0.1 Corrected IP RPZ convertion
#
###########################

# routine for ensuring all necessary dependencies are found
check_deps () {
  DEPS="date grep mv rm sed wget whoami su sort uniq wc"
  MISSING_DEPS=0

  for NEEDED_DEP in $DEPS; do
    if ! hash "$NEEDED_DEP" > /dev/null 2>&1; then
      printf "Command not found in PATH: %s\n" "$NEEDED_DEP" >&2
      MISSING_DEPS=$((MISSING_DEPS+1))
    fi
  done
  if [ $MISSING_DEPS -gt 0 ]; then
    printf "%d commands not found in PATH; aborting\n" "$MISSING_DEPS" >&2
    exit 1
  fi
}

# verify running as proper user if not, attempt to switch and abort if cannot
check_user () {
  USER=$(whoami)
  if [ "$USER" != "DNSServer" ]; then
    echo "Running as user $USER; switching to user DNSServer" >&2
    su -m DNSServer "$0" "$@" || exit 1
    exit 0
  fi
}

# check for configuration files & create files / templates if not present
check_conf () {
  # check zone.load.conf
  echo 'Looking up zone.load.conf file...' >&2
  if [ -f "$NAMED_ZONE_LOAD_CFG_FILE" ]; then
    echo ' - File found' >&2
    # check if file includes RPZ Blocklist
    if grep -q "include[[:space:]]*\"/etc/zone/data/${RPZ_BLOCKLIST_NAME//./\.}\"" "$NAMED_ZONE_LOAD_CFG_FILE"; then
      echo ' - Loader includes RPZ Blocklist' >&2
    else
      echo " ! Zone $RPZ_BLOCKLIST_NAME is missing! Exiting" >&2
      exit 1
    fi
    # check if file includes Sinkhole Zone
    if grep -q "include[[:space:]]*\"/etc/zone/data/${SINKHOLE_ZONE_NAME//./\.}\"" "$NAMED_ZONE_LOAD_CFG_FILE"; then
      echo ' - Loader includes Sinkhole Zone' >&2
    else
      echo " ! Zone $SINKHOLE_ZONE_NAME is missing! Exiting" >&2
      exit 1
    fi
  else
    echo ' ! File is missing! Exiting' >&2
    exit 1
  fi

  # create the RPZ Blocklist Zone File
  [ -f "$RPZ_BLOCKLIST_DEF_FILE" ] && rm -f "$RPZ_BLOCKLIST_DEF_FILE"
  { echo "zone \"$RPZ_BLOCKLIST_NAME\" {";
    echo -e "\ttype master;";
    echo -e "\tfile \"/etc/zone/master/$RPZ_BLOCKLIST_NAME\";";
    echo -e "\tallow-update {none;};";
    echo -e "\tallow-transfer {none;};";
    echo -e "\tallow-query {none;};";
    echo "};";
  } > "$RPZ_BLOCKLIST_DEF_FILE"

  # make sure the BIND user conf has a response-policy section with the RPZ blocklist Zone
  echo 'Looking up BIND Options User Conf...' >&2
  if [ -f "$NAMED_OPT_USR_CFG_FILE" ]; then
    echo ' - File found' >&2
    if grep -q "response-policy[[:space:]]*{" "$NAMED_OPT_USR_CFG_FILE"; then
      echo ' - Found Response Policy Section' >&2
      if grep -q "zone[[:space:]]*\"${RPZ_BLOCKLIST_NAME//./\.}\";" "$NAMED_OPT_USR_CFG_FILE"; then
        echo ' - Blocklist RPZ is included' >&2
      else
        echo ' ! Blocklist RPZ missing, adding it...' >&2
        sed -i "/response-policy {/ a \\\tzone \"$RPZ_BLOCKLIST_NAME\";" "$NAMED_OPT_USR_CFG_FILE"
        echo ' - Blocklist RPZ added to Response Policy Section' >&2
      fi
    else
      echo ' ! Response Policy Section missing, adding it...' >&2
      { echo "response-policy {";
        echo -e "\tzone \"$RPZ_BLOCKLIST_NAME\";";
        echo "};";
      } >> "$NAMED_OPT_USR_CFG_FILE"
      echo ' - Response Policy Section with Blocklist RPZ added to User Options Conf File' >&2
    fi
  else
    echo ' ! File is missing, creating it with Response Policy Section with Blocklist RPZ' >&2
    { echo "response-policy {";
      echo -e "\tzone \"$RPZ_BLOCKLIST_NAME\";";
      echo "};";
    } > "$NAMED_OPT_USR_CFG_FILE"
  fi

  # if no ServerList found, then create a template & instructions
  if [ ! -f "$SL_CFG_FILE" ]; then
    echo "No server list found; creating template" >&2
    { echo "# List of blocklists urls for ad-blocker.sh";
      echo "# The blocklists must just be one provider URL per line (no Bind or Hosts format)";
      echo "# Comments are indicated by a '#' as the first character";
      echo "https://pgl.yoyo.org/as/serverlist.php?hostformat=list&showintro=0&mimetype=plaintext";
      echo "https://v.firebog.net/hosts/Easylist.txt";
      echo "https://gist.githubusercontent.com/BBcan177/b96dd281c5acd5327825a22c63f9f9c9/raw/94c1585a189347e35c0070a9e4de76fde2adb271/liste_fr.txt";
    } > "$SL_CFG_FILE"
  fi

  # if no whitelist found, then create a template & instructions
  if [ ! -f "$WL_CFG_FILE" ]; then
    echo "No white list found; creating template" >&2
    { echo "# White list of domains or IPs to remain unblocked for ad-blocker.sh";
      echo "# Add one FQDN or IP per line";
      echo "# Comments are indicated by a '#' as the first character";
      echo "# example:";
      echo "# ad.example.com";
    } > "$WL_CFG_FILE"
  fi

  # if no blacklist found, then create a template & instructions
  if [ ! -f "$BL_CFG_FILE" ]; then
    echo "No black list found; creating template" >&2
    { echo "# Black list of additional domains or IPs for ad-blocker.sh";
      echo "# Add one FQDN or IP per line";
      echo "# Comments are indicted by a '#' as the first character";
      echo "# example:";
      echo "# ad.example.com";
    } > "$BL_CFG_FILE"
  fi
}

fetch_blocklists () {
  echo "Fetching block lists from servers in conf" >&2
  while IFS= read -r LINE; do
    BlocklistURL=$(echo "$LINE" | grep -v "^[[:space:]*\#]")
    if [ -z "$BlocklistURL" ]; then
      continue;
    fi
    echo " - Getting list from $BlocklistURL" >&2
    wget -qO- "$BlocklistURL" | sed -e '/^\s*#.*$/d' -e '/^\s*$/d' >> "$TEMP_FILE1"
  done < "$SL_CFG_FILE"
  mv "$TEMP_FILE1" "$TEMP_FILE2"
}

apply_blacklist () {
  # skip if the config doesn't exist
  if [ ! -f "$BL_CFG_FILE" ]; then
    return 0;
  fi

  sed -e '/^\s*#.*$/d' -e '/^\s*$/d' "$BL_CFG_FILE" >> "$TEMP_FILE2"
  echo "Added Entries from User defined Blacklist" >&2
}

remove_duplicates () {
  sort "$TEMP_FILE2" | uniq > "$TEMP_FILE1"
  DUP_COUNT=$(($(wc -l < "$TEMP_FILE2")-$(wc -l < "$TEMP_FILE1")))
  mv "$TEMP_FILE1" "$TEMP_FILE2"
  echo "Removed $DUP_COUNT duplicate entries" >&2
}

# user-specified list of domains to remain unblocked
apply_whitelist () {
  # skip if the config doesn't exist
  if [ ! -f "$WL_CFG_FILE" ]; then
    return 0
  fi

  # process the whitelist skipping over any comment lines
  while read -r LINE; do
    # strip the line if it starts with a '#' if the line was stripped, then continue on to the next line
    ENTRY=$(echo "$LINE" | grep -v "^[[:space:]*\#]")
    if [ -z "$ENTRY" ]; then
      continue;
    fi

    sed -i "/^$ENTRY$/d" "$TEMP_FILE2"
  done < "$WL_CFG_FILE"
  echo "Removed User defined Whitelist entries" >&2
}

rpz_ipv4 () {
  local IFS
  IFS=.
  set -- $1
  echo -n "32.$4.$3.$2.$1.rpz-ip"
}

rpz_ipv6 () {
  RESULT='rpz-ip'
  local IFS
  IFS=:
  set -f
  for BITGROUP in ${1/::/:zz:}; do
    RESULT="$BITGROUP#!/bin/bash
###########################
# (C) 2020 bOLEMO
# based on the original ad-blockerscript for Synology by Steven Black
# inspired by -Setting up a DNS Firewall on steroids- by NavyTitanium
###########################
#
# 2017-04-17 - 1.x.x Initial Adblock script by Steven Black
# 2020-02-23 - 1.1.5 Allow to set blacklist(s) from a conf file
# 2020-03-10 - 2.0.0 Now using RPZ
# 2020-03-15 - 2.0.1 Corrected IP RPZ convertion
#
###########################

# routine for ensuring all necessary dependencies are found
check_deps () {
  DEPS="date grep mv rm sed wget whoami su sort uniq wc"
  MISSING_DEPS=0

  for NEEDED_DEP in $DEPS; do
    if ! hash "$NEEDED_DEP" > /dev/null 2>&1; then
      printf "Command not found in PATH: %s\n" "$NEEDED_DEP" >&2
      MISSING_DEPS=$((MISSING_DEPS+1))
    fi
  done
  if [ $MISSING_DEPS -gt 0 ]; then
    printf "%d commands not found in PATH; aborting\n" "$MISSING_DEPS" >&2
    exit 1
  fi
}

# verify running as proper user if not, attempt to switch and abort if cannot
check_user () {
  USER=$(whoami)
  if [ "$USER" != "DNSServer" ]; then
    echo "Running as user $USER; switching to user DNSServer" >&2
    su -m DNSServer "$0" "$@" || exit 1
    exit 0
  fi
}

# check for configuration files & create files / templates if not present
check_conf () {
  # check zone.load.conf
  echo 'Looking up zone.load.conf file...' >&2
  if [ -f "$NAMED_ZONE_LOAD_CFG_FILE" ]; then
    echo ' - File found' >&2
    # check if file includes RPZ Blocklist
    if grep -q "include[[:space:]]*\"/etc/zone/data/${RPZ_BLOCKLIST_NAME//./\.}\"" "$NAMED_ZONE_LOAD_CFG_FILE"; then
      echo ' - Loader includes RPZ Blocklist' >&2
    else
      echo " ! Zone $RPZ_BLOCKLIST_NAME is missing! Exiting" >&2
      exit 1
    fi
    # check if file includes Sinkhole Zone
    if grep -q "include[[:space:]]*\"/etc/zone/data/${SINKHOLE_ZONE_NAME//./\.}\"" "$NAMED_ZONE_LOAD_CFG_FILE"; then
      echo ' - Loader includes Sinkhole Zone' >&2
    else
      echo " ! Zone $SINKHOLE_ZONE_NAME is missing! Exiting" >&2
      exit 1
    fi
  else
    echo ' ! File is missing! Exiting' >&2
    exit 1
  fi

  # create the RPZ Blocklist Zone File
  [ -f "$RPZ_BLOCKLIST_DEF_FILE" ] && rm -f "$RPZ_BLOCKLIST_DEF_FILE"
  { echo "zone \"$RPZ_BLOCKLIST_NAME\" {";
    echo -e "\ttype master;";
    echo -e "\tfile \"/etc/zone/master/$RPZ_BLOCKLIST_NAME\";";
    echo -e "\tallow-update {none;};";
    echo -e "\tallow-transfer {none;};";
    echo -e "\tallow-query {none;};";
    echo "};";
  } > "$RPZ_BLOCKLIST_DEF_FILE"

  # make sure the BIND user conf has a response-policy section with the RPZ blocklist Zone
  echo 'Looking up BIND Options User Conf...' >&2
  if [ -f "$NAMED_OPT_USR_CFG_FILE" ]; then
    echo ' - File found' >&2
    if grep -q "response-policy[[:space:]]*{" "$NAMED_OPT_USR_CFG_FILE"; then
      echo ' - Found Response Policy Section' >&2
      if grep -q "zone[[:space:]]*\"${RPZ_BLOCKLIST_NAME//./\.}\";" "$NAMED_OPT_USR_CFG_FILE"; then
        echo ' - Blocklist RPZ is included' >&2
      else
        echo ' ! Blocklist RPZ missing, adding it...' >&2
        sed -i "/response-policy {/ a \\\tzone \"$RPZ_BLOCKLIST_NAME\";" "$NAMED_OPT_USR_CFG_FILE"
        echo ' - Blocklist RPZ added to Response Policy Section' >&2
      fi
    else
      echo ' ! Response Policy Section missing, adding it...' >&2
      { echo "response-policy {";
        echo -e "\tzone \"$RPZ_BLOCKLIST_NAME\";";
        echo "};";
      } >> "$NAMED_OPT_USR_CFG_FILE"
      echo ' - Response Policy Section with Blocklist RPZ added to User Options Conf File' >&2
    fi
  else
    echo ' ! File is missing, creating it with Response Policy Section with Blocklist RPZ' >&2
    { echo "response-policy {";
      echo -e "\tzone \"$RPZ_BLOCKLIST_NAME\";";
      echo "};";
    } > "$NAMED_OPT_USR_CFG_FILE"
  fi

  # if no ServerList found, then create a template & instructions
  if [ ! -f "$SL_CFG_FILE" ]; then
    echo "No server list found; creating template" >&2
    { echo "# List of blocklists urls for ad-blocker.sh";
      echo "# The blocklists must just be one provider URL per line (no Bind or Hosts format)";
      echo "# Comments are indicated by a '#' as the first character";
      echo "https://pgl.yoyo.org/as/serverlist.php?hostformat=list&showintro=0&mimetype=plaintext";
      echo "https://v.firebog.net/hosts/Easylist.txt";
      echo "https://gist.githubusercontent.com/BBcan177/b96dd281c5acd5327825a22c63f9f9c9/raw/94c1585a189347e35c0070a9e4de76fde2adb271/liste_fr.txt";
    } > "$SL_CFG_FILE"
  fi

  # if no whitelist found, then create a template & instructions
  if [ ! -f "$WL_CFG_FILE" ]; then
    echo "No white list found; creating template" >&2
    { echo "# White list of domains or IPs to remain unblocked for ad-blocker.sh";
      echo "# Add one FQDN or IP per line";
      echo "# Comments are indicated by a '#' as the first character";
      echo "# example:";
      echo "# ad.example.com";
    } > "$WL_CFG_FILE"
  fi

  # if no blacklist found, then create a template & instructions
  if [ ! -f "$BL_CFG_FILE" ]; then
    echo "No black list found; creating template" >&2
    { echo "# Black list of additional domains or IPs for ad-blocker.sh";
      echo "# Add one FQDN or IP per line";
      echo "# Comments are indicted by a '#' as the first character";
      echo "# example:";
      echo "# ad.example.com";
    } > "$BL_CFG_FILE"
  fi
}

fetch_blocklists () {
  echo "Fetching block lists from servers in conf" >&2
  while IFS= read -r LINE; do
    BlocklistURL=$(echo "$LINE" | grep -v "^[[:space:]*\#]")
    if [ -z "$BlocklistURL" ]; then
      continue;
    fi
    echo " - Getting list from $BlocklistURL" >&2
    wget -qO- "$BlocklistURL" | sed -e '/^\s*#.*$/d' -e '/^\s*$/d' >> "$TEMP_FILE1"
  done < "$SL_CFG_FILE"
  mv "$TEMP_FILE1" "$TEMP_FILE2"
}

apply_blacklist () {
  # skip if the config doesn't exist
  if [ ! -f "$BL_CFG_FILE" ]; then
    return 0;
  fi

  sed -e '/^\s*#.*$/d' -e '/^\s*$/d' "$BL_CFG_FILE" >> "$TEMP_FILE2"
  echo "Added Entries from User defined Blacklist" >&2
}

remove_duplicates () {
  sort "$TEMP_FILE2" | uniq > "$TEMP_FILE1"
  DUP_COUNT=$(($(wc -l < "$TEMP_FILE2")-$(wc -l < "$TEMP_FILE1")))
  mv "$TEMP_FILE1" "$TEMP_FILE2"
  echo "Removed $DUP_COUNT duplicate entries" >&2
}

# user-specified list of domains to remain unblocked
apply_whitelist () {
  # skip if the config doesn't exist
  if [ ! -f "$WL_CFG_FILE" ]; then
    return 0
  fi

  # process the whitelist skipping over any comment lines
  while read -r LINE; do
    # strip the line if it starts with a '#' if the line was stripped, then continue on to the next line
    ENTRY=$(echo "$LINE" | grep -v "^[[:space:]*\#]")
    if [ -z "$ENTRY" ]; then
      continue;
    fi

    sed -i "/^$ENTRY$/d" "$TEMP_FILE2"
  done < "$WL_CFG_FILE"
  echo "Removed User defined Whitelist entries" >&2
}

rpz_ipv4 () {
  local IFS
  IFS=.
  set -- $1
  echo -n "32.$4.$3.$2.$1.rpz-ip"
}

rpz_ipv6 () {
  RESULT='rpz-ip'
  local IFS
  IFS=:
  set -f
  for bitgroup in ${1/::/:zz:}; do
    RESULT="$bitgroup.$RESULT"
  done
  set +f
  echo -n "128.$RESULT"
}

build_rpz_zone_file () {
  echo "Building RPZ Blocklist Database..." >&2
  NOW=$(date +"%Y%m%d%H")

  # build the rpz zone file with the updated serial number
  { echo '$TTL 300';
    echo "@ IN SOA localhost. root.localhost. ( ${NOW} 10800 3600 604800 3600 )";
    echo '@ IN NS localhost.'; } > "$TEMP_FILE1"

  # add each domain/ip from blocklist to rpz zone file
  IPCOUNT=0
  DOMCOUNT=0
  while IFS= read -r ENTRY; do
    if [[ $ENTRY =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      # ENTRY is an IPV4 adress
      echo "$(rpz_ipv4 $ENTRY) IN CNAME drop.$SINKHOLE_ZONE_NAME." >> "$TEMP_FILE1"
      IPCOUNT=$((IPCOUNT+1))
    elif [[ $ENTRY =~ ^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$ ]]; then
      # ENTRY is an IPV6 adress
      echo "$(rpz_ipv6 $ENTRY) IN CNAME drop.$SINKHOLE_ZONE_NAME." >> "$TEMP_FILE1"
      IPCOUNT=$((IPCOUNT+1))
    else
      # ENTRY is not an IP adress
      { echo "*.$ENTRY IN CNAME drop.$SINKHOLE_ZONE_NAME.";
        echo "$ENTRY IN CNAME drop.$SINKHOLE_ZONE_NAME."; } >> "$TEMP_FILE1"
        DOMCOUNT=$((DOMCOUNT+1))
    fi
  done < "$TEMP_FILE2"
  mv "$TEMP_FILE1" "$TEMP_FILE2"
  echo " - done, with $((DOMCOUNT+IPCOUNT)) entries ($DOMCOUNT domains and $IPCOUNT IPs)" >&2
}

# set the rpz zone file and reload BIND config
finalize () {
  # move the final version of the block list to the final location
  mv "$TEMP_FILE2" "$RPZ_BLOCKLIST_DB_FILE"

  # reload the BIND config to pick up the changes
  "$DNSS_SCRIPT_DIR"/reload.sh
}

# Global vars for common paths
TEMP_DIR="/tmp"
TEMP_FILE1="$TEMP_DIR/ad-blocker-workfile1.tmp"
TEMP_FILE2="$TEMP_DIR/ad-blocker-workfile2.tmp"

CONF_DIR="/usr/local/etc"
SL_CFG_FILE="$CONF_DIR/ad-blocker-sl.conf"
BL_CFG_FILE="$CONF_DIR/ad-blocker-bl.conf"
WL_CFG_FILE="$CONF_DIR/ad-blocker-wl.conf"

DNSS_ROOT_DIR="/var/packages/DNSServer"
DNSS_SCRIPT_DIR="$DNSS_ROOT_DIR/target/script"
NAMED_ROOT_DIR="$DNSS_ROOT_DIR/target/named"

NAMED_CFG_DIR="$NAMED_ROOT_DIR/etc/conf"
NAMED_OPT_USR_CFG_FILE="$NAMED_CFG_DIR/named.options.user.conf"

NAMED_ZONE_DIR="$NAMED_ROOT_DIR/etc/zone"
NAMED_ZONE_LOAD_CFG_FILE="$NAMED_ZONE_DIR/zone.load.conf"

NAMED_ZONE_DATA_DIR="$NAMED_ZONE_DIR/data"
NAMED_ZONE_MASTER_DIR="$NAMED_ZONE_DIR/master"
RPZ_BLOCKLIST_NAME="rpz.blocklist"
RPZ_BLOCKLIST_DEF_FILE="$NAMED_ZONE_DATA_DIR/$RPZ_BLOCKLIST_NAME"
RPZ_BLOCKLIST_DB_FILE="$NAMED_ZONE_MASTER_DIR/$RPZ_BLOCKLIST_NAME"

SINKHOLE_ZONE_NAME="sinkhole"

# Main Routine
check_deps
check_user "$@"
check_conf
fetch_blocklists
apply_blacklist
remove_duplicates
apply_whitelist
build_rpz_zone_file
finalize
exit 0.$RESULT"
  done
  set +f
  echo -n "128.$RESULT"
}

build_rpz_zone_file () {
  echo "Building RPZ Blocklist Database..." >&2
  NOW=$(date +"%Y%m%d%H")

  # build the rpz zone file with the updated serial number
  { echo '$TTL 300';
    echo "@ IN SOA localhost. root.localhost. ( ${NOW} 10800 3600 604800 3600 )";
    echo '@ IN NS localhost.'; } > "$TEMP_FILE1"

  # add each domain/ip from blocklist to rpz zone file
  IPCOUNT=0
  DOMCOUNT=0
  while IFS= read -r ENTRY; do
    if [[ $ENTRY =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      # ENTRY is an IPV4 adress
      echo "$(rpz_ipv4 $ENTRY) IN CNAME drop.$SINKHOLE_ZONE_NAME." >> "$TEMP_FILE1"
      IPCOUNT=$((IPCOUNT+1))
    elif [[ $ENTRY =~ ^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$ ]]; then
      # ENTRY is an IPV6 adress
      echo "$(rpz_ipv6 $ENTRY) IN CNAME drop.$SINKHOLE_ZONE_NAME." >> "$TEMP_FILE1"
      IPCOUNT=$((IPCOUNT+1))
    else
      # ENTRY is not an IP adress
      { echo "*.$ENTRY IN CNAME drop.$SINKHOLE_ZONE_NAME.";
        echo "$ENTRY IN CNAME drop.$SINKHOLE_ZONE_NAME."; } >> "$TEMP_FILE1"
        DOMCOUNT=$((DOMCOUNT+1))
    fi
  done < "$TEMP_FILE2"
  mv "$TEMP_FILE1" "$TEMP_FILE2"
  echo " - done, with $((DOMCOUNT+IPCOUNT)) entries ($DOMCOUNT domains and $IPCOUNT IPs)" >&2
}

#!/bin/bash
###########################
# (C) 2020 bOLEMO
# based on the original ad-blockerscript for Synology by Steven Black
# inspired by -Setting up a DNS Firewall on steroids- by NavyTitanium
###########################
#
# 2017-04-17 - 1.x.x Initial Adblock script by Steven Black
# 2020-02-23 - 1.1.5 Allow to set blacklist(s) from a conf file
# 2020-03-10 - 2.0.0 Now using RPZ
# 2020-03-15 - 2.0.1 Corrected IP RPZ convertion
#
###########################

# routine for ensuring all necessary dependencies are found
check_deps () {
  DEPS="date grep mv rm sed wget whoami su sort uniq wc"
  MISSING_DEPS=0

  for NEEDED_DEP in $DEPS; do
    if ! hash "$NEEDED_DEP" > /dev/null 2>&1; then
      printf "Command not found in PATH: %s\n" "$NEEDED_DEP" >&2
      MISSING_DEPS=$((MISSING_DEPS+1))
    fi
  done
  if [ $MISSING_DEPS -gt 0 ]; then
    printf "%d commands not found in PATH; aborting\n" "$MISSING_DEPS" >&2
    exit 1
  fi
}

# verify running as proper user if not, attempt to switch and abort if cannot
check_user () {
  USER=$(whoami)
  if [ "$USER" != "DNSServer" ]; then
    echo "Running as user $USER; switching to user DNSServer" >&2
    su -m DNSServer "$0" "$@" || exit 1
    exit 0
  fi
}

# check for configuration files & create files / templates if not present
check_conf () {
  # check zone.load.conf
  echo 'Looking up zone.load.conf file...' >&2
  if [ -f "$NAMED_ZONE_LOAD_CFG_FILE" ]; then
    echo ' - File found' >&2
    # check if file includes RPZ Blocklist
    if grep -q "include[[:space:]]*\"/etc/zone/data/${RPZ_BLOCKLIST_NAME//./\.}\"" "$NAMED_ZONE_LOAD_CFG_FILE"; then
      echo ' - Loader includes RPZ Blocklist' >&2
    else
      echo " ! Zone $RPZ_BLOCKLIST_NAME is missing! Exiting" >&2
      exit 1
    fi
    # check if file includes Sinkhole Zone
    if grep -q "include[[:space:]]*\"/etc/zone/data/${SINKHOLE_ZONE_NAME//./\.}\"" "$NAMED_ZONE_LOAD_CFG_FILE"; then
      echo ' - Loader includes Sinkhole Zone' >&2
    else
      echo " ! Zone $SINKHOLE_ZONE_NAME is missing! Exiting" >&2
      exit 1
    fi
  else
    echo ' ! File is missing! Exiting' >&2
    exit 1
  fi

  # create the RPZ Blocklist Zone File
  [ -f "$RPZ_BLOCKLIST_DEF_FILE" ] && rm -f "$RPZ_BLOCKLIST_DEF_FILE"
  { echo "zone \"$RPZ_BLOCKLIST_NAME\" {";
    echo -e "\ttype master;";
    echo -e "\tfile \"/etc/zone/master/$RPZ_BLOCKLIST_NAME\";";
    echo -e "\tallow-update {none;};";
    echo -e "\tallow-transfer {none;};";
    echo -e "\tallow-query {none;};";
    echo "};";
  } > "$RPZ_BLOCKLIST_DEF_FILE"

  # make sure the BIND user conf has a response-policy section with the RPZ blocklist Zone
  echo 'Looking up BIND Options User Conf...' >&2
  if [ -f "$NAMED_OPT_USR_CFG_FILE" ]; then
    echo ' - File found' >&2
    if grep -q "response-policy[[:space:]]*{" "$NAMED_OPT_USR_CFG_FILE"; then
      echo ' - Found Response Policy Section' >&2
      if grep -q "zone[[:space:]]*\"${RPZ_BLOCKLIST_NAME//./\.}\";" "$NAMED_OPT_USR_CFG_FILE"; then
        echo ' - Blocklist RPZ is included' >&2
      else
        echo ' ! Blocklist RPZ missing, adding it...' >&2
        sed -i "/response-policy {/ a \\\tzone \"$RPZ_BLOCKLIST_NAME\";" "$NAMED_OPT_USR_CFG_FILE"
        echo ' - Blocklist RPZ added to Response Policy Section' >&2
      fi
    else
      echo ' ! Response Policy Section missing, adding it...' >&2
      { echo "response-policy {";
        echo -e "\tzone \"$RPZ_BLOCKLIST_NAME\";";
        echo "};";
      } >> "$NAMED_OPT_USR_CFG_FILE"
      echo ' - Response Policy Section with Blocklist RPZ added to User Options Conf File' >&2
    fi
  else
    echo ' ! File is missing, creating it with Response Policy Section with Blocklist RPZ' >&2
    { echo "response-policy {";
      echo -e "\tzone \"$RPZ_BLOCKLIST_NAME\";";
      echo "};";
    } > "$NAMED_OPT_USR_CFG_FILE"
  fi

  # if no ServerList found, then create a template & instructions
  if [ ! -f "$SL_CFG_FILE" ]; then
    echo "No server list found; creating template" >&2
    { echo "# List of blocklists urls for ad-blocker.sh";
      echo "# The blocklists must just be one provider URL per line (no Bind or Hosts format)";
      echo "# Comments are indicated by a '#' as the first character";
      echo "https://pgl.yoyo.org/as/serverlist.php?hostformat=list&showintro=0&mimetype=plaintext";
      echo "https://v.firebog.net/hosts/Easylist.txt";
      echo "https://gist.githubusercontent.com/BBcan177/b96dd281c5acd5327825a22c63f9f9c9/raw/94c1585a189347e35c0070a9e4de76fde2adb271/liste_fr.txt";
    } > "$SL_CFG_FILE"
  fi

  # if no whitelist found, then create a template & instructions
  if [ ! -f "$WL_CFG_FILE" ]; then
    echo "No white list found; creating template" >&2
    { echo "# White list of domains or IPs to remain unblocked for ad-blocker.sh";
      echo "# Add one FQDN or IP per line";
      echo "# Comments are indicated by a '#' as the first character";
      echo "# example:";
      echo "# ad.example.com";
    } > "$WL_CFG_FILE"
  fi

  # if no blacklist found, then create a template & instructions
  if [ ! -f "$BL_CFG_FILE" ]; then
    echo "No black list found; creating template" >&2
    { echo "# Black list of additional domains or IPs for ad-blocker.sh";
      echo "# Add one FQDN or IP per line";
      echo "# Comments are indicted by a '#' as the first character";
      echo "# example:";
      echo "# ad.example.com";
    } > "$BL_CFG_FILE"
  fi
}

fetch_blocklists () {
  echo "Fetching block lists from servers in conf" >&2
  while IFS= read -r LINE; do
    BlocklistURL=$(echo "$LINE" | grep -v "^[[:space:]*\#]")
    if [ -z "$BlocklistURL" ]; then
      continue;
    fi
    echo " - Getting list from $BlocklistURL" >&2
    wget -qO- "$BlocklistURL" | sed -e '/^\s*#.*$/d' -e '/^\s*$/d' >> "$TEMP_FILE1"
  done < "$SL_CFG_FILE"
  mv "$TEMP_FILE1" "$TEMP_FILE2"
}

apply_blacklist () {
  # skip if the config doesn't exist
  if [ ! -f "$BL_CFG_FILE" ]; then
    return 0;
  fi

  sed -e '/^\s*#.*$/d' -e '/^\s*$/d' "$BL_CFG_FILE" >> "$TEMP_FILE2"
  echo "Added Entries from User defined Blacklist" >&2
}

remove_duplicates () {
  sort "$TEMP_FILE2" | uniq > "$TEMP_FILE1"
  DUP_COUNT=$(($(wc -l < "$TEMP_FILE2")-$(wc -l < "$TEMP_FILE1")))
  mv "$TEMP_FILE1" "$TEMP_FILE2"
  echo "Removed $DUP_COUNT duplicate entries" >&2
}

# user-specified list of domains to remain unblocked
apply_whitelist () {
  # skip if the config doesn't exist
  if [ ! -f "$WL_CFG_FILE" ]; then
    return 0
  fi

  # process the whitelist skipping over any comment lines
  while read -r LINE; do
    # strip the line if it starts with a '#' if the line was stripped, then continue on to the next line
    ENTRY=$(echo "$LINE" | grep -v "^[[:space:]*\#]")
    if [ -z "$ENTRY" ]; then
      continue;
    fi

    sed -i "/^$ENTRY$/d" "$TEMP_FILE2"
  done < "$WL_CFG_FILE"
  echo "Removed User defined Whitelist entries" >&2
}

rpz_ipv4 () {
  local IFS
  IFS=.
  set -- $1
  echo -n "32.$4.$3.$2.$1.rpz-ip"
}

rpz_ipv6 () {
  RESULT='rpz-ip'
  local IFS
  IFS=:
  set -f
  for BITGROUP in ${1/::/:zz:}; do
    RESULT="$BITGROUP.$RESULT"
  done
  set +f
  echo -n "128.$RESULT"
}

build_rpz_zone_file () {
  echo "Building RPZ Blocklist Database..." >&2
  NOW=$(date +"%Y%m%d%H")

  # build the rpz zone file with the updated serial number
  { echo '$TTL 300';
    echo "@ IN SOA localhost. root.localhost. ( ${NOW} 10800 3600 604800 3600 )";
    echo '@ IN NS localhost.'; } > "$TEMP_FILE1"

  # add each domain/ip from blocklist to rpz zone file
  IPCOUNT=0
  DOMCOUNT=0
  while IFS= read -r ENTRY; do
    if [[ $ENTRY =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      # ENTRY is an IPV4 adress
      echo "$(rpz_ipv4 $ENTRY) IN CNAME drop.$SINKHOLE_ZONE_NAME." >> "$TEMP_FILE1"
      IPCOUNT=$((IPCOUNT+1))
    elif [[ $ENTRY =~ ^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$ ]]; then
      # ENTRY is an IPV6 adress
      echo "$(rpz_ipv6 $ENTRY) IN CNAME drop.$SINKHOLE_ZONE_NAME." >> "$TEMP_FILE1"
      IPCOUNT=$((IPCOUNT+1))
    else
      # ENTRY is not an IP adress
      { echo "*.$ENTRY IN CNAME drop.$SINKHOLE_ZONE_NAME.";
        echo "$ENTRY IN CNAME drop.$SINKHOLE_ZONE_NAME."; } >> "$TEMP_FILE1"
        DOMCOUNT=$((DOMCOUNT+1))
    fi
  done < "$TEMP_FILE2"
  mv "$TEMP_FILE1" "$TEMP_FILE2"
  echo " - done, with $((DOMCOUNT+IPCOUNT)) entries ($DOMCOUNT domains and $IPCOUNT IPs)" >&2
}

# set the rpz zone file and reload BIND config
finalize () {
  # move the final version of the block list to the final location
  mv "$TEMP_FILE2" "$RPZ_BLOCKLIST_DB_FILE"

  # reload the BIND config to pick up the changes
  "$DNSS_SCRIPT_DIR"/reload.sh
}

# Global vars for common paths
TEMP_DIR="/tmp"
TEMP_FILE1="$TEMP_DIR/ad-blocker-workfile1.tmp"
TEMP_FILE2="$TEMP_DIR/ad-blocker-workfile2.tmp"

CONF_DIR="/usr/local/etc"
SL_CFG_FILE="$CONF_DIR/ad-blocker-sl.conf"
BL_CFG_FILE="$CONF_DIR/ad-blocker-bl.conf"
WL_CFG_FILE="$CONF_DIR/ad-blocker-wl.conf"

DNSS_ROOT_DIR="/var/packages/DNSServer"
DNSS_SCRIPT_DIR="$DNSS_ROOT_DIR/target/script"
NAMED_ROOT_DIR="$DNSS_ROOT_DIR/target/named"

NAMED_CFG_DIR="$NAMED_ROOT_DIR/etc/conf"
NAMED_OPT_USR_CFG_FILE="$NAMED_CFG_DIR/named.options.user.conf"

NAMED_ZONE_DIR="$NAMED_ROOT_DIR/etc/zone"
NAMED_ZONE_LOAD_CFG_FILE="$NAMED_ZONE_DIR/zone.load.conf"

NAMED_ZONE_DATA_DIR="$NAMED_ZONE_DIR/data"
NAMED_ZONE_MASTER_DIR="$NAMED_ZONE_DIR/master"
RPZ_BLOCKLIST_NAME="rpz.blocklist"
RPZ_BLOCKLIST_DEF_FILE="$NAMED_ZONE_DATA_DIR/$RPZ_BLOCKLIST_NAME"
RPZ_BLOCKLIST_DB_FILE="$NAMED_ZONE_MASTER_DIR/$RPZ_BLOCKLIST_NAME"

SINKHOLE_ZONE_NAME="sinkhole"

# Main Routine
check_deps
check_user "$@"
check_conf
fetch_blocklists
apply_blacklist
remove_duplicates
apply_whitelist
build_rpz_zone_file
finalize
exit 0
