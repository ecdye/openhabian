#!/usr/bin/env bash
# shellcheck disable=SC2181

## Function for installing NodeJS for frontail and other addons.
##
##    nodejs_setup()
##
nodejs_setup() {
  if node_is_installed && ! is_armv6l; then return 0; fi

  local keyName="nodejs"
  local link="https://nodejs.org/dist/v18.16.1/node-v18.16.1-linux-armv7l.tar.xz"
  local myDistro
  local temp


  myDistro="$(lsb_release -sc | head -1)"
  if [[ "$myDistro" == "n/a" ]] || running_in_docker; then
    myDistro=${osrelease:-bookworm}
  fi
  temp="$(mktemp "${TMPDIR:-/tmp}"/openhabian.XXXXX)"

  if [[ -z $PREOFFLINE ]] && is_armv6l; then
    echo -n "$(timestamp) [openHABian] Installing NodeJS... "
    if ! cond_redirect wget -qO "$temp" "$link"; then echo "FAILED (download)"; rm -f "$temp"; return 1; fi
    if ! cond_redirect tar -Jxf "$temp" --strip-components=1 -C /usr; then echo "FAILED (extract)"; rm -f "$temp"; return 1; fi
    if cond_redirect rm -f "$temp"; then echo "OK"; else echo "FAILED (cleanup)"; return 1; fi
  else
    if [[ -z $OFFLINE ]]; then
      if ! add_keys "https://deb.nodesource.com/gpgkey/nodesource.gpg.key" "$keyName"; then return 1; fi

      echo -n "$(timestamp) [openHABian] Adding NodeSource repository to apt... "
      echo "deb [signed-by=/usr/share/keyrings/${keyName}.gpg] https://deb.nodesource.com/node_18.x $myDistro main" > /etc/apt/sources.list.d/nodesource.list
      echo "deb-src [signed-by=/usr/share/keyrings/${keyName}.gpg] https://deb.nodesource.com/node_18.x $myDistro main" >> /etc/apt/sources.list.d/nodesource.list
      if [[ -n $PREOFFLINE ]]; then
        if cond_redirect apt-get --quiet update; then echo "OK"; else echo "FAILED (update apt lists)"; return 1; fi
      else
        if cond_redirect apt-get update; then echo "OK"; else echo "FAILED (update apt lists)"; return 1; fi
      fi
    fi

    echo -n "$(timestamp) [openHABian] Installing NodeJS... "
    if [[ -n $PREOFFLINE ]]; then
      if cond_redirect apt-get --quiet install --download-only --yes nodejs; then echo "OK"; else echo "FAILED"; return 1; fi
    else
      if cond_redirect apt-get install --yes -o DPkg::Lock::Timeout="$APTTIMEOUT" nodejs; then echo "OK"; else echo "FAILED"; return 1; fi
    fi
    if [[ "$myDistro" == "bookworm" ]]; then jsscripting_npm_install; fi
    if ! command -v npm &> /dev/null; then
      echo -n "$(timestamp) [openHABian] Installing npm ... "
      #if cond_redirect apt-get install --yes -o DPkg::Lock::Timeout="$APTTIMEOUT" npm; then echo "OK"; else echo "FAILED (install npm)"; return 1; fi
      if cond_redirect apt-get install --yes -o DPkg::Lock::Timeout="$APTTIMEOUT" npm; then echo "OK"; else echo "FAILED (install npm)"; fi
    fi
  fi
}

## Function for downloading frontail to current system
##
##    frontail_download(String prefix)
##
frontail_download() {
  echo -n "$(timestamp) [openHABian] Downloading frontail... "
  if ! [[ -d "${1}/frontail" ]]; then
    cond_echo "\\nFresh Installation... "
    if cond_redirect git clone https://github.com/Interstellar0verdrive/frontail_AEM.git "${1}/frontail"; then echo "OK"; else echo "FAILED (git clone)"; return 1; fi
  else
    cond_echo "\\nUpdate... "
    if cond_redirect update_git_repo "${1}/frontail" "master"; then echo "OK"; else echo "FAILED (update git repo)"; return 1; fi
  fi
}

## Function for removing frontail as its insecure and not maintained.
##
##    frontail_remove()
##
frontail_remove() {
  local frontailBase
  local frontailDir="/opt/frontail"
  local removeText="Frontail is a log viewer that is not maintained and has security issues. As of openHAB 4.3 there is a built in log viewer which replaces it.\\n\\nWould you like to remove it from your system? If not, be aware that it is not recommended to use it and is no longer a supported feature of openHABian."
  local rememberChoice="Would you like to remember this choice for future runs of openHABian?"

  frontailBase="$(npm list -g | head -n 1)/node_modules/frontail"

  if ! dpkg --compare-versions "$(sed -n 's/openhab-distro\s*: //p' /var/lib/openhab/etc/version.properties)" gt "4.3.0"; then return 0; fi
  if [[ -z $INTERACTIVE ]] || [[ -n $frontail_remove ]]; then return 0; fi


  if [[ -d $frontailBase ]] || [[ -d $frontailDir ]]; then
    if (whiptail --title "Frontail Removal" --yes-button "Remove" --no-button "Keep" --yesno "$removeText" 27 84); then
      echo -n "$(timestamp) [openHABian] Removing openHAB Log Viewer frontail... "
      if [[ $(systemctl is-active frontail.service) == "active" ]]; then
        if ! cond_redirect systemctl stop frontail.service; then echo "FAILED (stop service)"; return 1; fi
      fi
      if ! cond_redirect systemctl disable frontail.service; then echo "FAILED (disable service)"; return 1; fi
      cond_redirect npm uninstall -g frontail
      rm -f /etc/systemd/system/frontail.service
      rm -rf /var/log/frontail
      rm -rf /opt/frontail

      if grep -qs "frontail-link" "/etc/openhab/services/runtime.cfg"; then
        cond_redirect sed -i -e "/frontail-link/d" "/etc/openhab/services/runtime.cfg"
      fi
      if cond_redirect systemctl -q daemon-reload; then echo "OK"; else echo "FAILED (daemon-reload)"; return 1; fi
    elif (whiptail --title "Frontail Removal" --yes-button "Don't show again" --no-button "Keep showing" --yesno "$rememberChoice" 10 84); then
        # shellcheck source=/etc/openhabian.conf disable=SC2154
        sed -i -e "s/^.*frontail_remove.*$/frontail_remove=true/g" "${configFile}"
    fi
  fi
}

## Function for installing frontail to enable the openHAB log viewer web application.
##
##    frontail_setup()
##
frontail_setup() {
  local frontailBase
  local frontailUser="frontail"

  if ! node_is_installed || is_armv6l; then
    echo -n "$(timestamp) [openHABian] Installing Frontail prerequsites (NodeJS)... "
    if cond_redirect nodejs_setup; then echo "OK"; else echo "FAILED"; return 1; fi
  fi

  frontailBase="$(npm list -g | head -n 1)/node_modules/frontail"

  if ! (id -u ${frontailUser} &> /dev/null || cond_redirect useradd --groups "${username:-openhabian}",openhab -s /bin/bash -d /var/tmp ${frontailUser}); then echo "FAILED (adduser)"; return 1; fi

  echo -n "$(timestamp) [openHABian] Installing openHAB Log Viewer (frontail)... "
  if [[ -d $frontailBase ]]; then
    cond_echo "Removing any old installations... "
    cond_redirect npm uninstall -g frontail
  fi

  if ! cond_redirect frontail_download "/opt"; then echo "FAILED (download)"; return 1; fi
  cd /opt/frontail || (echo "FAILED (cd)"; return 1)
  # npm arguments explained:
  #   --omit=dev ignores the dev dependencies (we do not require them for production usage)
  # Do NOT catch exit 1 for npm audit fix, because it's thrown when a vulnerability can't be fixed. Happens when a fix requires an upgrade to a new major release with possible breaking changes.
  cond_redirect npm audit fix --omit=dev
  if ! cond_redirect npm update --audit=false --omit=dev; then echo "FAILED (update)"; return 1; fi
  if cond_redirect npm install --global --audit=false --omit=dev; then echo "OK"; else echo "FAILED (install)"; return 1; fi

  echo -n "$(timestamp) [openHABian] Setting up openHAB Log Viewer (frontail) service... "
  if ! (sed -e "s|%FRONTAILBASE|${frontailBase}|g" "${BASEDIR:-/opt/openhabian}"/includes/frontail.service > /etc/systemd/system/frontail.service); then echo "FAILED (service file creation)"; return 1; fi
  if ! cond_redirect chmod 644 /etc/systemd/system/frontail.service; then echo "FAILED (permissions)"; return 1; fi
  if ! cond_redirect systemctl -q daemon-reload; then echo "FAILED (daemon-reload)"; return 1; fi
  if ! cond_redirect systemctl enable --now frontail.service; then echo "FAILED (enable service)"; return 1; fi
  if cond_redirect systemctl restart frontail.service; then echo "OK"; else echo "FAILED (restart service)"; return 1; fi # Restart the service to make the change visible

  if openhab_is_installed; then
    dashboard_add_tile "frontail"
  fi
}

## Function for adding/removing a user specifed log to/from frontail
##
##    custom_frontail_log()
##
custom_frontail_log() {
  local frontailService="/etc/systemd/system/frontail.service"
  local addLog
  local removeLog
  local array

  if ! [[ -f $frontailService ]]; then
    if [[ -n $INTERACTIVE ]]; then  whiptail --title "Frontail not installed" --msgbox "Frontail is not installed!\\n\\nCanceling operation!" 9 80; fi
    return 0
  fi

  if [[ $1 == "add" ]]; then
    if [[ -n $INTERACTIVE ]]; then
      if ! addLog="$(whiptail --title "Enter file path" --inputbox "\\nEnter the path to the logfile that you would like to add to frontail:" 9 80 3>&1 1>&2 2>&3)"; then echo "CANCELED"; return 0; fi
    else
      if [[ -n $2 ]]; then addLog="$2"; else return 0; fi
    fi

    for log in "${addLog[@]}"; do
      if [[ -f $log ]]; then
        echo -n "$(timestamp) [openHABian] Adding '${log}' to frontail... "
        if ! cond_redirect sed -i -e "/^ExecStart/ s|$| ${log}|" "$frontailService"; then echo "FAILED (add log)"; return 1; fi
        if ! cond_redirect systemctl -q daemon-reload; then echo "FAILED (daemon-reload)"; return 1; fi
        if cond_redirect systemctl restart frontail.service; then echo "OK"; else echo "FAILED (restart service)"; return 1; fi
      else
        if [[ -n $INTERACTIVE ]]; then
          whiptail --title "File does not exist" --msgbox "The specifed file path does not exist!\\n\\nCanceling operation!" 9 80
          return 0
        else
          echo "$(timestamp) [openHABian] Adding '${log}' to frontail... FAILED (file does not exist)"
        fi
      fi
    done
  elif [[ $1 == "remove" ]] && [[ -n $INTERACTIVE ]]; then
    readarray -t array < <(grep -e "^ExecStart.*$" "$frontailService" | awk '{for (i=12; i<=NF; i++) {printf "%s\n\n", $i}}')
    ((count=${#array[@]} + 6))
    removeLog="$(whiptail --title "Select log to remove" --cancel-button Cancel --ok-button Select --menu "\\nPlease choose the log that you would like to remove from frontail:\\n" "$count" 80 0 "${array[@]}" 3>&1 1>&2 2>&3)"
    if ! cond_redirect sed -i -e "s|${removeLog}||" -e '/^ExecStart/ s|[[:space:]]\+| |g' "$frontailService"; then echo "FAILED (remove log)"; return 1; fi
    if ! cond_redirect systemctl -q daemon-reload; then echo "FAILED (daemon-reload)"; return 1; fi
    if cond_redirect systemctl restart frontail.service; then echo "OK"; else echo "FAILED (restart service)"; return 1; fi
  fi
}

## Function for installing Node-RED a flow based programming interface for IoT devices.
##
##    nodered_setup()
##
nodered_setup() {
  if [[ -z $INTERACTIVE ]]; then
    echo "$(timestamp) [openHABian] Node-RED setup must be run in interactive mode! Canceling Node-RED setup!"
    echo "CANCELED"
    return 0
  fi

  local temp

  if ! node_is_installed || is_armv6l; then
    echo -n "$(timestamp) [openHABian] Installing Frontail prerequsites (NodeJS)... "
    if cond_redirect nodejs_setup; then echo "OK"; else echo "FAILED"; return 1; fi
  fi
  if ! dpkg -s 'build-essential' &> /dev/null; then
    echo -n "$(timestamp) [openHABian] Installing Node-RED required packages (build-essential)... "
    if cond_redirect apt-get install --yes -o DPkg::Lock::Timeout="$APTTIMEOUT" build-essential; then echo "OK"; else echo "FAILED"; return 1; fi
  fi

  temp="$(mktemp "${TMPDIR:-/tmp}"/openhabian.XXXXX)"

  echo -n "$(timestamp) [openHABian] Downloading Node-RED setup script... "
  if cond_redirect wget -qO "$temp" https://raw.githubusercontent.com/node-red/linux-installers/master/deb/update-nodejs-and-nodered; then
     echo "OK"
  else
    echo "FAILED"
    rm -f "$temp"
    return 1
  fi

  echo -n "$(timestamp) [openHABian] Setting up Node-RED... "
  whiptail --title "Node-RED Setup" --msgbox "The installer is about to ask for information in the command line, please fill out each line." 8 80 3>&1 1>&2 2>&3
  chmod 755 "$temp"
  if sudo -u "${username:-openhabian}" -H bash -c "$temp"; then echo "OK"; rm -f "$temp"; else echo "FAILED"; rm -f "$temp"; return 1; fi

  echo -n "$(timestamp) [openHABian] Installing Node-RED addons... "
  if ! cond_redirect npm install -g node-red-contrib-bigtimer; then echo "FAILED (install bigtimer addon)"; return 1; fi
  if ! cond_redirect npm update -g node-red-contrib-bigtimer; then echo "FAILED (update bigtimer addon)"; return 1; fi
  if ! cond_redirect npm install -g node-red-contrib-openhab3; then echo "FAILED (install openhab3 addon)"; return 1; fi
  if cond_redirect npm update -g node-red-contrib-openhab3; then echo "OK"; else echo "FAILED (update openhab3 addon)"; return 1; fi

  echo -n "$(timestamp) [openHABian] Setting up Node-RED service... "
  if ! cond_redirect systemctl -q daemon-reload; then echo "FAILED (daemon-reload)"; return 1; fi
  if cond_redirect systemctl enable --now nodered.service; then echo "OK"; else echo "FAILED (enable service)"; return 1; fi

  if openhab_is_installed; then
    dashboard_add_tile "nodered"
  fi
}

## Function for downloading zigbee2mqtt to current system
##
##    zigbee2mqtt_download(String prefix)
##
zigbee2mqtt_download() {
  echo -n "$(timestamp) [openHABian] Downloading Zigbee2MQTT... "
  if ! cond_redirect mkdir -p /opt/zigbee2mqtt; then echo "FAILED (mkdir -p /opt/zigbee2mqtt)"; fi
  if ! cond_redirect chown "${username:-openhabian}:openhab" /opt/zigbee2mqtt; then echo "FAILED (chown /opt/zigbee2mqtt)"; fi
  if ! cond_redirect sudo -u "${username:-openhabian}" git clone https://github.com/Koenkk/zigbee2mqtt.git "/opt/zigbee2mqtt"; then echo "FAILED (git clone)"; return 1; fi
}

## Function for installing zigbee2mqtt.
##
##    zigbee2mqtt_setup()
##
zigbee2mqtt_setup() {
  local zigbee2mqttBase
  local z2mInstalledText="A configuration for Zigbee2MQTT is already existing.\\n\\nWould you like to update Zigbee2MQTT to the latest version with this configuration?"
  local introText="A MQTT-server is required for Zigbee2mqtt. If you haven't installed one yet, please select <cancel> and come back after installing one (e.g. Mosquitto).\\n\\nZigbee2MQTT will be installed from the official repository.\\n\\nDuration is about 4 minutes... "
  local installText="Zigbee2MQTT is installed from the official repository.\\n\\nPlease wait about 4 minutes... "
  local uninstallText="Zigbee2MQTT will be completely removed from the system."
  local adapterText="Please select your zigbee adapter:"
  local adapterNetw="\\nPlease specify the ip:port of the zigbee coordinator."
  local mqttUserText="\\nPlease enter your MQTT-User (default = openhabian):"
  local mqttPWText="\\nIf your MQTT-server requires a password, please enter it here:"
  local my_adapters
  local by_path_or_id
  local mqttDefaultUser="${username:-openhabian}"
  local mqttUser
  local serverIP
  local installSuccessText
  local updateSuccessText
  local loopSel=1

  serverIP="$(hostname -I)"; serverIP=${serverIP::-1} # remove trailing space
  installSuccessText="Setup was successful. Zigbee2MQTT is now up and running.\\n\\nFor further Zigbee-settings open frontend (in 2 minutes): \\nhttp://${serverIP}:8081.\\n\\nDocumentation of ZigBee2MQTT:\\nhttps://www.zigbee2mqtt.io/guide/configuration"
  updateSuccessText="Update successful. \\n\\nFor further Zigbee-settings open frontend (in 2 minutes): \\nhttp://${serverIP}:8081.\\n\\nDocumentation of Zigbee2MQTT:\\nhttps://www.zigbee2mqtt.io/guide/configuration"

  if [[ $1 == "remove" ]]; then
    if [[ -n $INTERACTIVE ]]; then
      if ! (whiptail --title "Zigbee2MQTT Uninstall" --yes-button "Continue" --no-button "Cancel" --yesno "$uninstallText" 7 80); then echo "CANCELED"; return 0; fi
    fi
    echo -n "$(timestamp) [openHABian] Removing Zigbee2MQTT service... "
    systemctl stop zigbee2mqtt.service
    if ! rm -f /etc/systemd/system/zigbee2mqtt.service; then echo "FAILED (remove service)"; return 1; fi
    if cond_redirect systemctl -q daemon-reload; then echo "OK"; else  echo "FAILED (daemon-reload)"; return 1; fi

    echo -n "$(timestamp) [openHABian] Uninstalling Zigbee2MQTT... "
    if ! cond_redirect npm uninstall zigbee2mqtt ; then echo "FAILED (npm uninstall)"; return 1; fi
    if ! rm -rf /var/log/zigbee2mqtt; then echo "FAILED (remove log)"; return 1; fi
    if rm -rf "/opt/zigbee2mqtt"; then echo "OK"; else echo "FAILED (rm /opt/zigbee2mqtt)"; return 1; fi

    if [[ -n "$INTERACTIVE" ]]; then
      whiptail --title "Zigbee2MQTT removed" --msgbox "Zigbee2MQTT was removed from your system." 7 80
    fi
    return 0;
  fi
  if [[ $1 != "install" ]]; then return 1; fi

  # if a config file exists do only update and exit
  if [[ -e "/opt/zigbee2mqtt/data/configuration.yaml" ]] ; then
    if [[ -n $INTERACTIVE ]]; then
      if ! (whiptail --title "Zigbee2MQTT installation" --yes-button "Continue" --no-button "Cancel" --yesno "$z2mInstalledText" 14 80); then echo "CANCELED"; return 0; fi
    fi

    echo -n "$(timestamp) [openHABian] Updating Zigbee2MQTT... "
    if ! cond_redirect cd /opt/zigbee2mqtt; then echo "FAILED (cd zigbee2mqtt)"; return 1; fi
    if ! cond_redirect systemctl stop zigbee2mqtt ; then echo "FAILED (stop systemctl)"; fi
    if ! cond_redirect sudo -u "${username:-openhabian}" cp -R data data-backup; then echo "FAILED (cp backup)"; return 1; fi
    if ! cond_redirect sudo -u "${username:-openhabian}" git fetch origin; then echo "FAILED git fetch"; return 1; fi
    if ! cond_redirect sudo -u "${username:-openhabian}" git fetch --tags; then echo "FAILED git fetch"; return 1; fi
    if ! cond_redirect sudo -u "${username:-openhabian}" git checkout 1.42.0; then echo "FAILED git checkout"; return 1; fi

    if ! cond_redirect sudo -u "${username:-openhabian}" npm ci; then echo "FAILED npm"; return 1; fi
    if ! cond_redirect sudo -u "${username:-openhabian}" cp -R data-backup/* data; then echo "FAILED (cp backup)"; return 1; fi
    if ! cond_redirect rm -rf /opt/zigbee2mqtt/data-backup; then echo "FAILED (rm data-backup)"; return 1; fi
    if ! cond_redirect cd /opt ; then echo "FAILED (cd opt)"; return 1; fi
    if ! cond_redirect systemctl start zigbee2mqtt; then echo "FAILED (systemctl start)"; return 1; fi

    if [[ -n $INTERACTIVE ]]; then
      whiptail --title "Operation successful" --msgbox "$updateSuccessText" 15 80
    fi
    echo "OK"
    return 0
  fi

  # get usb adapters for radio menu
  while IFS= read -r line; do
    my_adapters="$my_adapters $line $loopSel "
    by_path_or_id="/dev/serial/by-id"
    loopSel=0
  done < <( ls /dev/serial/by-id )

  if [[ $my_adapters == "" ]] ; then
    while IFS= read -r line; do
      my_adapters="$my_adapters $line $loopSel "
      by_path_or_id="/dev/serial/by-path"
      loopSel=0
    done < <( ls /dev/serial/by-path )
  fi

  unset IFS

  # ask for user input parameters
  if [[ -n $INTERACTIVE ]]; then
    if ! (whiptail --title "Zigbee2MQTT installation" --yes-button "Continue" --no-button "Cancel" --yesno "$introText" 14 80); then echo "CANCELED"; return 0; fi
    # shellcheck disable=SC2086
    if ! zigmode=$(whiptail --title "Zigbee2MQTT installation" --menu "Choose mode:" 14 100 2 --cancel-button "Cancel" --ok-button "Continue" \
    "usb"  "The zigbee coordinator is directly connected to this computer." \
    "network"  "The zigbee coordinator is connected to the LAN and has an IP address." \
    3>&1 1>&2 2>&3); then echo "CANCELED"; return 0; fi
    # shellcheck disable=SC2086

    if [[ $zigmode == "network" ]] ; then
      if ! selectedAdapter=$(whiptail --title "Zigbee Network Coordinator" --inputbox "$adapterNetw" 10 80 "xxx.xxx.xxx.xxx:port" 3>&1 1>&2 2>&3); then return 0; fi
      by_path_or_id="tcp:/"
    else
      if ! selectedAdapter=$(whiptail --noitem --title "Zigbee2MQTT installation" --radiolist "$adapterText" 14 100 4 $my_adapters 3>&1 1>&2 2>&3); then return 0; fi
    fi
    if ! mqttUser=$(whiptail --title "MQTT User" --inputbox "$mqttUserText" 10 80 "$mqttDefaultUser" 3>&1 1>&2 2>&3); then return 0; fi
    if ! mqttPW=$(whiptail --title "MQTT password" --passwordbox "$mqttPWText" 10 80 3>&1 1>&2 2>&3); then return 0; fi
    if ! (whiptail --title "Zigbee2MQTT installation" --infobox "$installText" 14 80); then echo "CANCELED"; return 0; fi
  fi

  if ! cond_redirect nodejs_setup; then return 1; fi

  echo -n "$(timestamp) [openHABian] Downloading Zigbee2MQTT... "
  zigbee2mqttBase="$(npm list | head -n 1)/node_modules/zigbee2mqtt"
  if [[ -d $zigbee2mqttBase ]]; then
    if cond_redirect systemctl stop zigbee2mqtt.service; then echo "OK (stop service)"; else echo "FAILED (stop service)"; return 1; fi # Stop the service
    cond_echo "Removing any old installations... "
    cond_redirect npm uninstall zigbee2mqtt
  fi
  if ! cond_redirect zigbee2mqtt_download "/opt"; then echo "FAILED (download)"; return 1; fi
  echo "OK"

  echo -n "$(timestamp) [openHABian] Creating log directory... "
  mkdir  -p /var/log/zigbee2mqtt || (echo "FAILED (create log-directory)"; return 1)
  chown "${username:-openhabian}:openhab" /var/log/zigbee2mqtt || (echo "FAILED (create log-directory)"; return 1)
  echo "OK"

  echo -n "$(timestamp) [openHABian] Zigbee2MQTT install & config... "
  cd /opt/zigbee2mqtt || (echo "FAILED (cd)"; return 1)
  if ! cond_redirect sudo -u "${username:-openhabian}" git fetch origin; then echo "FAILED git fetch"; return 1; fi
  if ! cond_redirect sudo -u "${username:-openhabian}" git fetch --tags; then echo "FAILED git fetch"; return 1; fi
  if ! cond_redirect sudo -u "${username:-openhabian}" git checkout 1.42.0; then echo "FAILED git checkout"; return 1; fi
  if ! cond_redirect sudo -u "${username:-openhabian}" npm ci ; then echo "FAILED (npm ci)"; return 1; fi

  if ! cond_redirect install -o "${username:-openhabian}" -g openhab -m 644 "${BASEDIR:-/opt/openhabian}/includes/zigbee2mqtt/configuration.yaml" /opt/zigbee2mqtt/data/; then echo "FAILED (install configuration.yaml)"; return 1; fi
  sed -i -e "s|%adapter%|$by_path_or_id/$selectedAdapter|g" /opt/zigbee2mqtt/data/configuration.yaml
  sed -i -e "s|%user%|$mqttUser|g" /opt/zigbee2mqtt/data/configuration.yaml
  sed -i -e "s|%password%|$mqttPW|g" /opt/zigbee2mqtt/data/configuration.yaml

  cd /opt || (echo "FAILED (cd)"; return 1)
  echo "OK"

  echo -n "$(timestamp) [openHABian] Setting up Zigbee2MQTT service... "

  if ! cond_redirect install -o "${username:-openhabian}" -g openhab -m 644 "${BASEDIR:-/opt/openhabian}/includes/zigbee2mqtt/zigbee2mqtt.service" /etc/systemd/system/; then echo "FAILED (install service)"; return 1; fi
  sed -i -e "s|%user%|${username:-openhabian}|g" "/etc/systemd/system/zigbee2mqtt.service"

  if ! cond_redirect systemctl -q daemon-reload; then echo "FAILED (daemon-reload)"; return 1; fi
  if ! cond_redirect systemctl enable --now zigbee2mqtt.service; then echo "FAILED (enable service)"; return 1; fi
  echo "OK"

  if [[ -n $INTERACTIVE ]]; then
    whiptail --title "Operation successful" --msgbox "$installSuccessText" 15 80
  fi
}

## Function for installing a npm package for the JS Scripting Automation Add-On
##
##    jsscripting_npm_install(String packageName, String mode)
##    Available values for mode: "update", install", "uninstall". Defaults to "install".
##
jsscripting_npm_install() {
  if [ "${1}" == "" ]; then echo "FAILED. Provide packageName."; return 1; fi

  local openhabJsText="A version of the openHAB JavaScript is included in the JS Scripting add-on, therefore there is no general need for manual installation it.\\n\\nPlease only continue if you know what you want."

  if ! node_is_installed || is_armv6l; then
    echo -n "$(timestamp) [openHABian] Installing prerequisites for ${1} (NodeJS)... "
    if cond_redirect nodejs_setup; then echo "OK"; else echo "FAILED"; return 1; fi
  fi

  if [ "${2}" == "uninstall" ];
  then
    echo -n "$(timestamp) [openHABian] Uninstalling ${1} from JS Scripting... "
    if cond_redirect sudo -u "openhab" npm remove --prefix "/etc/openhab/automation/js" "${1}@latest"; then echo "OK"; else echo "FAILED (npm remove)"; return 1; fi
  else
    echo -n "$(timestamp) [openHABian] Installing ${1} for JS Scripting... "
    if [[ "${1}" == "openhab" ]] && [[ "${2}" != "update" ]] && [[ -n $INTERACTIVE ]]; then
      if (whiptail --title "Installation of openhab for JS Scripting" --yes-button "Continue" --no-button "Cancel" --yesno "${openhabJsText}" 15 80); then echo -n "INSTALLING "; else echo "SKIP"; return 0; fi
    fi
    if ! cond_redirect sudo -u "openhab" mkdir -p /etc/openhab/automation/js; then echo "FAILED (mkdir /etc/openhab/automation/js)"; fi
    if cond_redirect sudo -u "openhab" npm install --prefix "/etc/openhab/automation/js" "${1}@latest"; then echo "OK"; else echo "FAILED (npm install)"; return 1; fi
  fi
}

## Function for checking for updates of a npm package for the JS Scripting Automation Add-On
##
##    jsscripting_npm_check(String packageName)
##
jsscripting_npm_check() {
  if [ "${1}" == "" ]; then echo "FAILED. Provide packageName."; return 1; fi
  # If directory of package doesn't exist, exit.
  if [ ! -d "/etc/openhab/automation/js/node_modules/${1}" ]; then return 0; fi

  local introText="Additions, improvements or fixes were added to ${1} (npm package) for JS Scripting. Would you like to update now and benefit from them?"
  local breakingText="\\n\\nThis update includes BREAKING CHANGES!"
  local data
  local wantedVersion
  local latestVersion

  if ! node_is_installed || is_armv6l; then
    echo -n "$(timestamp) [openHABian] Installing prerequsites for ${1} for JS Scripting (NodeJS)... "
    if cond_redirect nodejs_setup; then echo "OK"; else echo "FAILED"; return 1; fi
  fi

  echo -n "$(timestamp) [openHABian] Checking for updates of ${1} for JS Scripting... "
  data=$(npm outdated --prefix /etc/openhab/automation/js --json)

  # Check whether data includes the packageName.
  if [[ "${data}" =~ \"${1}\" ]];
  then
    echo -n "Update available... "
    wantedVersion=$(echo "${data}" | jq ".${1}" | jq '.wanted' | sed -r 's/"//g' | sed -r 's/.[0-9].[0-9]//g')
    latestVersion=$(echo "${data}" | jq ".${1}" | jq '.latest' | sed -r 's/"//g' | sed -r 's/.[0-9].[0-9]//g')
    if [[ "${wantedVersion}" -lt "${latestVersion}" ]]; then
      echo "New major version... "
      if [[ -n $INTERACTIVE ]]; then
        if [[ "$1" == "openhab" ]]; then breakingText+="\\nPlease read the changelog (https://github.com/openhab/openhab-js/blob/main/CHANGELOG.md)."; fi
        if (whiptail --title "Update available for ${1} for JS Scripting" --yes-button "Continue" --no-button "Skip" --yesno "${introText}${breakingText}" 15 80); then echo "UPDATING"; else echo "SKIP"; return 0; fi
      fi
    else
      echo
      if [[ -n $INTERACTIVE ]]; then
        if [[ "$1" == "openhab" ]]; then introText+="\\nYou may read the changelog (https://github.com/openhab/openhab-js/blob/main/CHANGELOG.md)."; fi
        if (whiptail --title "Update available for ${1} for JS Scripting" --yes-button "Continue" --no-button "Skip" --yesno "${introText}" 15 80); then echo "UPDATING"; else echo "SKIP"; return 0; fi
      fi
    fi
    jsscripting_npm_install "${1}" "update"
  else
    echo "No update available."
  fi
}
