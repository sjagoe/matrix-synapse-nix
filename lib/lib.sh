#!/usr/bin/env bash

set -eu
set -o pipefail

DIR="$(dirname "$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )")"

function log() {
    echo "$*" 1>&2
}

function error() {
    log "$*"
    exit 1
}

function check_requirements() {
    hcloud server list >/dev/null
}

if ! check_requirements; then
    error "Missing requirements or authentication for hcloud"
fi

function hostInfoJson() {
    local fqdn="$1"
    local hostInfoPath="$DIR/hosts/$fqdn/host.json"
    local hostDir=
    hostDir="$(dirname "$hostInfoPath")"

    if [[ ! -d "$hostDir" ]]; then
        mkdir -p "$hostDir"
    fi
    if [[ ! -f "$hostInfoPath" ]]; then
       echo '{}' > "$hostInfoPath"
    fi

    echo "$hostInfoPath"
}

function hostSecretsJson() {
    local fqdn="$1"
    local hostSecretsPath="$DIR/hosts/$fqdn/secrets.json"
    local hostDir=
    hostDir="$(dirname "$hostSecretsPath")"

    if [[ ! -d "$hostDir" ]]; then
        mkdir -p "$hostDir"
    fi
    if [[ ! -f "$hostSecretsPath" ]]; then
       echo '{}' > "$hostSecretsPath"
    fi

    echo "$hostSecretsPath"
}

function hcloudObjectId() {
    local type="$1"
    local name="$2"
    local objectid=
    objectid="$(hcloud "$type" list -ojson | jq --arg name "$name" -r '.[] | select(.name == $name) | .id')"
    if [ -z "$objectid" ]; then
        return 1
    else
        echo "$objectid"
    fi
}

function hcloudServerIP() {
    local fqdn="$1"
    local ipaddr=
    ipaddr="$(getServerInfo "$fqdn" ".ipv4.public.address")"
    if [ -z "$ipaddr" ]; then
        return 1
    else
        echo "$ipaddr"
    fi
}

function getServerInfo() {
    local fqdn="$1"
    local path="$2"
    local thing=
    local hostInfoPath=
    hostInfoPath="$(hostInfoJson "$fqdn")"
    thing="$(jq -r --arg fqdn "$fqdn" "${path}" < "$hostInfoPath")"
    if [ -z "$thing" ]; then
        return 1
    else
        echo "$thing"
    fi
}

function createdns() {
    local fqdn="$1"
    local ipaddr="$2"
    local ipv6="$3"

    log "Adding $fqdn A=$ipaddr and AAAA=$ipv6 to DNS"
    python "$DIR/bin/update-dns.py" add-host "$fqdn" "$ipaddr" "$ipv6" 1>&2
}

function createvolume() {
    local fqdn="$1"
    local location="$2"
    local size="$3"
    local servername="$1"
    local id=
    servername="$(fqdn2name "$fqdn")"
    local name="${servername}-data"

    if hcloudObjectId volume "$name" >/dev/null; then
        error "Volume with name $name already exists!"
    fi

    log "Creating data volume for $fqdn"
    hcloud volume create \
           --location "$location" \
           --size "$size" \
           --label "fqdn=$fqdn" \
           --name "$name" 1>&2

    id="$(hcloudObjectId volume "$name" || error "Volume $name not found after creation")"
    echo "$id"
}

function serverinfo() {
    local fqdn="$1"
    local name=
    local hcloudinfo=
    local info=
    local hostInfoPath=
    hostInfoPath="$(hostInfoJson "$fqdn")"

    name="$(fqdn2name "$fqdn")"
    hcloudinfo="$(hcloud server describe "$name" -ojson)"
    info="$(echo "$hcloudinfo" | jq  --arg fqdn "$fqdn" '{fqdn: $fqdn, created: .created, datacenter: .datacenter.name, id: .id, name: .name, ipv4: {public: {address: .public_net.ipv4.ip}}, ipv6: {prefix: .public_net.ipv6.ip}, type: .server_type.name, volumes: .volumes}')"

    jq --argjson info "$info" '. + $info' < "$hostInfoPath" > "${hostInfoPath}.tmp"
    mv "${hostInfoPath}.tmp" "$hostInfoPath"

    allocateIp "$fqdn" internal
    allocateIp "$fqdn" wireguard
    "$DIR/bin/allocateipv6.py" "$hostInfoPath"
}

function addserverinfo() {
    local fqdn="$1"
    local additionalInfo="$2"
    local hostInfoPath=
    hostInfoPath="$(hostInfoJson "$fqdn")"

    jq --argjson info "$additionalInfo" '. + $info' < "$hostInfoPath" > "${hostInfoPath}.tmp"
    mv "${hostInfoPath}.tmp" "$hostInfoPath"
}


function allocateIp() {
    local fqdn="$1"
    local network="$2"
    local ipaddr=
    python3 "$DIR/bin/allocateipv4.py" "$fqdn" "$network" "$DIR/hosts" "$DIR/network.json" 1>&2
    ipaddr="$(getServerInfo "$fqdn" ".ipv4.${network}")"
    log "Allocated new IP $ipaddr in network $network"
    echo "$ipaddr"
}

function generateWireguardKeys() {
    local fqdn="$1"
    local private=
    local public=
    local hostSecretsPath=
    hostSecretsPath="$(hostSecretsJson "$fqdn")"

    log "Generating wg keys for $fqdn"
    private="$(wg genkey)"
    public="$(echo -n "$private" | wg pubkey)"

    jq --arg private "$private" --arg public "$public" \
       '.wireguard = {private: $private, public: $public}' < "$hostSecretsPath" > "${hostSecretsPath}.tmp"
    mv "${hostSecretsPath}.tmp" "$hostSecretsPath"
}

function generateResticKey() {
    local fqdn="$1"
    local restickey=
    local hostSecretsPath=
    hostSecretsPath="$(hostSecretsJson "$fqdn")"
    restickey="$(pwgen -s -1 64)"

    jq --arg key "$restickey" '.restic = $key' < "$hostSecretsPath" > "${hostSecretsPath}.tmp"
    mv "${hostSecretsPath}.tmp" "$hostSecretsPath"

    log "Generated new restic key for $fqdn"
}

function createserver() {
    local fqdn="$1"
    local type="$2"
    local location="$3"
    local volumesize="$4"
    local sshkeyname="$5"
    local sshkey=
    local id=
    local name=
    local volume=

    name="$(fqdn2name "$fqdn")"

    sshkey="$(hcloudObjectId ssh-key "$sshkeyname" || error "ssh key $sshkeyname not found")"

    if hcloudObjectId server "$name" >/dev/null; then
        error "Server with name $name already exists!"
    fi

    log "Creating server $fqdn"
    hcloud server create \
           --location "$location" \
           --image ubuntu-20.04 \
           --type "$type" \
           --ssh-key "$sshkey" \
           --start-after-create=false \
           --network internal \
           --label "waiting-install=true" \
           --label "fqdn=${fqdn}" \
           --name "$name" 1>&2

    id="$(hcloudObjectId server "$name")"

    if [[ "$volumesize" -gt 0 ]]; then
        volume="$(createvolume "$fqdn" "$location" "$volumesize")"
        hcloud volume attach --server "$id" "$volume" 1>&2
    fi

    serverinfo "$fqdn"

    local ipaddr=
    local ipv6=
    ipaddr="$(hcloudServerIP "$fqdn")"
    ipv6="$(getServerInfo "$fqdn" ".ipv6.address")"
    createdns "$fqdn" "$ipaddr" "$ipv6"

    log "Updating $fqdn reverse DNS"
    hcloud server set-rdns -r "$fqdn" "$name" 1>&2
    hcloud server set-rdns -i "$ipv6" -r "$fqdn" "$name" 1>&2

    log "Server $fqdn created"
    echo "$id"
}

function waitforrunning() {
    local fqdn="$1"
    local identityfile="$2"
    set +u
    local checkhosts="$3"
    local knownhosts="$4"
    local user="$5"
    local ipaddr=
    if [[ -z "$checkhosts" ]]; then
        checkhosts=no
        knownhosts=/dev/null
    fi
    if [[ -z "$user" ]]; then
        user=root
    fi

    ipaddr="$(hcloudServerIP "$fqdn")"

    set -u
    log "Waiting for $fqdn ssh to be available"
    sleep 5
    while ! ssh \
              -o ConnectTimeout=15 \
              -o StrictHostKeyChecking="$checkhosts" \
              -o UserKnownHostsFile="$knownhosts" \
              -i "$identityfile" \
              "${user}@${ipaddr}" \
              true; do
        log "Timed out trying to connect."
        sleep 15
    done;
}

function unlock() {
    local fqdn="$1"
    local lukskey="$2"
    local identityfile="$3"
    local knownhosts=
    local ipaddr=
    ipaddr="$(hcloudServerIP "$fqdn")"

    if [[ "$lukskey" == "load" ]]; then
        lukskey="$(getlukskey "$fqdn")"
    fi

    knownhosts="$DIR/ssh/ssh_known_hosts.initrd"
    waitforrunning "$fqdn" "$identityfile" yes "$knownhosts"

    log "Unlocking $fqdn at boot"
    echo -n "$lukskey" | \
        ssh -o StrictHostKeyChecking=yes \
            -o UserKnownHostsFile="$knownhosts" \
            -i "$identityfile" "root@${ipaddr}" \
            ash -c 'cat > /crypt-ramfs/passphrase'

    # Wait a bit for boot up
    sleep 30

    # fixme: Username
    waitforrunning "$fqdn" "$identityfile" yes "$DIR/ssh/ssh_known_hosts" "sjagoe"
}

function getlukskey() {
    local fqdn="$1"
    local lukskey=
    local hostSecretsPath=
    hostSecretsPath="$(hostSecretsJson "$fqdn")"

    lukskey="$(jq -r '.luks' < "$hostSecretsPath")"
    echo "$lukskey"
}

function generatelukskey() {
    local fqdn="$1"
    local lukskey=
    local hostSecretsPath=
    hostSecretsPath="$(hostSecretsJson "$fqdn")"
    lukskey="$(pwgen -s -1 128)"

    jq --arg key "$lukskey" '.luks = $key' < "$hostSecretsPath" > "${hostSecretsPath}.tmp"
    mv "${hostSecretsPath}.tmp" "$hostSecretsPath"

    log "Generated new LUKS key for $fqdn"
    echo "$lukskey"
}

function sshkeyname() {
    local fqdn="$1"
    local type="$2"
    local initrd=
    set +u
    if [ -n "$3" ]; then
       initrd="/initrd"
    fi
    set -u
    echo "$DIR/hosts/${fqdn}/keys${initrd}/ssh_host_${type}_key"
}

function fqdn2name() {
    local fqdn="$1"
    local name=
    local domain=

    name="${fqdn//.*/}"
    domain="${fqdn#$name}"
    domain="${domain#.}"

    if [ -z "$domain" ]; then
        error "Unable to determine domain. Was $fqdn an FQDN?"
    fi

    echo "$name"
}

function fqdn2domain() {
    local fqdn="$1"
    local name=
    local domain=

    name="${fqdn//.*/}"
    domain="${fqdn#$name}"
    domain="${domain#.}"

    if [ -z "$domain" ]; then
        error "Unable to determine domain. Was $fqdn an FQDN?"
    fi

    echo "$domain"
}

function generateKnownHostsFiles() {
    local fqdn=
    local ipaddr=
    local wgaddr=
    declare -a hosts
    mapfile -t hosts < <(ls "$DIR/hosts/")

    {
        for fqdn in "${hosts[@]}"; do
            ipaddr="$(getServerInfo "$fqdn" ".ipv4.public")"
            wgaddr="$(getServerInfo "$fqdn" ".ipv4.wireguard" | sed 's/\/.*//')"
            for part in "$fqdn" "$ipaddr" "$wgaddr"; do
                echo "${part} $(cat "$DIR/hosts/${fqdn}/keys/ssh_host_ed25519_key.pub")"
                echo "${part} $(cat "$DIR/hosts/${fqdn}/keys/ssh_host_rsa_key.pub")"
            done
        done
    } | sort > "$DIR/ssh/ssh_known_hosts"

    {
        for fqdn in "${hosts[@]}"; do
            ipaddr="$(getServerInfo "$fqdn" ".ipv4.public")"
            wgaddr="$(getServerInfo "$fqdn" ".ipv4.wireguard" | sed 's/\/.*//')"
            for part in "$fqdn" "$ipaddr" "$wgaddr"; do
                echo "${part} $(cat "$DIR/hosts/${fqdn}/keys/initrd/ssh_host_ed25519_key.pub")"
                echo "${part} $(cat "$DIR/hosts/${fqdn}/keys/initrd/ssh_host_rsa_key.pub")"
            done
        done
    } | sort > "$DIR/ssh/ssh_known_hosts.initrd"
}

function delknownhosts() {
    local fqdn="$1"
    local ipaddr="$2"
    local wgaddr="$3"
    local knownhosts="$4"

    sed -e "/^${fqdn//\./\\.}/ d" \
        -e "/^${ipaddr//\./\\.}/ d" \
        -e "/^${wgaddr//\./\\.}/ d" < "$knownhosts" > "${knownhosts}.tmp"

    sort < "${knownhosts}.tmp" > "${knownhosts}.sorted"
    unlink "${knownhosts}.tmp"
    mv "${knownhosts}.sorted" "${knownhosts}"
}

function addknownhosts() {
    local fqdn="$1"
    local ipaddr="$2"
    local wgaddr="$3"
    local knownhosts="$4"
    local rsakeyfile="$5"
    local edkeyfile="$6"

    if [[ -f "$knownhosts" ]]; then
        sed -e "/^${fqdn//\./\\.}/ d" < "$knownhosts" > "${knownhosts}.tmp"
        sed -e "/^${ipaddr//\./\\.}/ d" < "$knownhosts.tmp" > "${knownhosts}.tmp1"
        sed -e "/^${wgaddr//\./\\.}/ d" < "$knownhosts.tmp1" > "${knownhosts}.tmp"
        unlink "${knownhosts}.tmp1"
    fi

    {
        echo "${fqdn} $(cat "$rsakeyfile")"
        echo "${ipaddr} $(cat "$rsakeyfile")"
        echo "${wgaddr} $(cat "$rsakeyfile")"
        echo "${fqdn} $(cat "$edkeyfile")"
        echo "${ipaddr} $(cat "$edkeyfile")"
        echo "${wgaddr} $(cat "$edkeyfile")"
    } >> "${knownhosts}.tmp"
    sort < "${knownhosts}.tmp" > "${knownhosts}.sorted"
    unlink "${knownhosts}.tmp"
    mv "${knownhosts}.sorted" "${knownhosts}"
}

function deletehostsshkey() {
    local path="$1"
    if [[ -f "$path" ]]; then
        rm "$path"
    fi
}

function gensshkey() {
    local path="$1"
    shift
    if [[ ! -f "$path" ]]; then
        ssh-keygen "$@" -f "$path"
    fi
}

function generatehostsshkeys() {
    local fqdn="$1"
    local ipaddr="$2"
    local wgaddr="$3"
    local regenkeys="$4"
    local name=
    local initrd=
    local keycomment="root@$fqdn"

    if [[ "$regenkeys" == "true" ]]; then
        delknownhosts "$fqdn" "$ipaddr" "$wgaddr" "$DIR/ssh/ssh_known_hosts.initrd"
        delknownhosts "$fqdn" "$ipaddr" "$wgaddr" "$DIR/ssh/ssh_known_hosts"

        deletehostsshkey "$(sshkeyname "$fqdn" "rsa")"
        deletehostsshkey "$(sshkeyname "$fqdn" "rsa" "initrd")"
        deletehostsshkey "$(sshkeyname "$fqdn" "ed25519")"
        deletehostsshkey "$(sshkeyname "$fqdn" "ed25519" "initrd")"
    fi

    initrd="$(dirname "$(sshkeyname "$fqdn" "" initrd)")"
    mkdir -p "$initrd"
    gensshkey "$(sshkeyname "$fqdn" "rsa")"            -C "$keycomment" -t rsa -b 4096 -N ""
    gensshkey "$(sshkeyname "$fqdn" "rsa" initrd)"     -C "$keycomment" -t rsa -b 4096 -N ""
    gensshkey "$(sshkeyname "$fqdn" "ed25519")"        -C "$keycomment" -t ed25519 -N ""
    gensshkey "$(sshkeyname "$fqdn" "ed25519" initrd)" -C "$keycomment" -t ed25519 -N ""

    log "Generated ssh host keys for $fqdn"

    addknownhosts "$fqdn" "$ipaddr" "$wgaddr" "$DIR/ssh/ssh_known_hosts.initrd" \
                  "$(sshkeyname "$fqdn" "rsa" initrd).pub" \
                  "$(sshkeyname "$fqdn" "ed25519" initrd).pub"
    addknownhosts "$fqdn" "$ipaddr" "$wgaddr" "$DIR/ssh/ssh_known_hosts" \
                  "$(sshkeyname "$fqdn" "rsa").pub" \
                  "$(sshkeyname "$fqdn" "ed25519").pub"

    log "Updated ssh known hosts to include $fqdn"
}

function reinstallserver() {
    local fqdn="$1"
    local sshkeyname="$2"
    set +u
    local regenkeys="$3"
    set -u
    local serverid=
    local CONFIRM=
    serverid="$(getServerInfo "$fqdn" ".id")"

    read -r -n 4 -p "This will completely destroy $fqdn and all data it contains. Type upper case YES to confirm" CONFIRM

    if [[ "$CONFIRM" != "YES" ]]; then
        error "Aborting"
    fi

    hcloud server poweroff "$serverid"
    hcloud server add-label "$serverid" waiting-install=true || true

    installserver "$fqdn" "$serverid" "$sshkeyname" "$regenkeys"
}

function installserver() {
    local fqdn="$1"
    local sshkeyname="$2"
    local id=
    local regenkeys=
    set +u
    if [[ -n "$4" ]]; then
        regenkeys=true
    fi
    set -u
    local identityfile="/home/sjagoe/.ssh/identities/personal/id_ed25519-2021-04-17"
    local ipaddr=
    local lukskey=
    local name=
    local domain=
    local privateIp=
    local privatePrefixLength=
    local wireguardIp=
    local serverInfo=
    local volumes=
    local volumeCount=
    local volumeid=
    local volumename=
    local volumeInstalled=
    local adminUser=
    local adminSSHKeys=
    declare -a files_to_copy

    log "Preparing to install $fqdn"

    id="$(getServerInfo "$fqdn" ".id")"
    name="$(fqdn2name "$fqdn")"
    domain="$(fqdn2domain "$fqdn")"
    privateIp="$(getServerInfo "$fqdn" ".ipv4.internal.address")"
    privatePrefixLength="$(getServerInfo "$fqdn" ".ipv4.internal.prefixLength")"
    log "Got private IP for $fqdn: $privateIp"
    wireguardIp="$(getServerInfo "$fqdn" ".ipv4.wireguard.address")"
    log "Got wireguard IP for $fqdn: $wireguardIp"

    ipaddr="$(hcloudServerIP "$fqdn")"
    log "Got public IP for $fqdn: $ipaddr"

    local waitingInstall=
    waitingInstall="$(hcloud server describe "$id" -ojson | jq -r '.labels["waiting-install"]')"
    if [[ "$waitingInstall" != "true" ]]; then
        error "Server does not appear to have the waiting-install=true label!"
    fi

    set +x
    lukskey="$(generatelukskey "$fqdn")"

    volumes="$(getServerInfo "$fqdn" .volumes)"
    volumeCount="$(echo "$volumes" | jq '. | length')"

    generatehostsshkeys "$fqdn" "$ipaddr" "$wireguardIp" "$regenkeys"
    generateWireguardKeys "$fqdn"
    generateResticKey "$fqdn"

    log "Enabling rescue for $fqdn"
    hcloud server enable-rescue \
           --ssh-key "$sshkeyname" \
           "$id"
    hcloud server poweron "$id"
    log "Powered on $fqdn"

    log "Waiting for server to boot $fqdn"
    waitforrunning "$fqdn" "$identityfile"

    hcloud server remove-label "$id" waiting-install
    log "Copying install files to rescue $fqdn"
    files_to_copy=(
        "$DIR/lib/cloud-install-rescue.sh"
        "$DIR/lib/install-nix.sh"
    )

    for file in "${files_to_copy[@]}"; do
        scp \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -i "$identityfile" \
            "$file" \
            "root@${ipaddr}:"
    done

    if [[ "$volumeCount" -gt 0 ]]; then
        volumename="${name}-data"
        volumeid="$(hcloudObjectId volume "$volumename")"
        volumeInstalled="$(hcloud volume describe "$volumeid" -ojson | jq -r '.labels["installed"]')"
    fi

    adminUser="$(jq -r .ssh.nixopsAdmin < "$DIR/secrets.json")"
    adminSSHKeys="$(jq -c --arg admin "$adminUser" '.ssh.users[$admin]' < "$DIR/secrets.json")"

    set +x
    log "Preparing install for $fqdn"
    echo "$lukskey" | ssh \
                          -o StrictHostKeyChecking=no \
                          -o UserKnownHostsFile=/dev/null \
                          -i "$identityfile" \
                          "root@${ipaddr}" \
                          ./cloud-install-rescue.sh \
                          "$name" "$domain" "$privateIp/${privatePrefixLength}" \
                          "$adminUser" "$adminSSHKeys" "$volumeInstalled"

    if [[ "$volumeCount" -gt 0 ]] && [[ -z "$volumeInstalled" ]]; then
        hcloud volume add-label "$volumeid" installed=true || true
    fi

    log "Copying host ssh keys for $fqdn"
    files_to_copy=(
        "$(sshkeyname "$fqdn" "rsa")"
        "$(sshkeyname "$fqdn" "ed25519")"
        "$(sshkeyname "$fqdn" "rsa").pub"
        "$(sshkeyname "$fqdn" "ed25519").pub"
    )
    for file in "${files_to_copy[@]}"; do
        scp \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -i "$identityfile" \
            "$file" \
            "root@${ipaddr}:/mnt/etc/ssh"
    done

    log "Copying host ssh keys for initrd $fqdn"
    files_to_copy=(
        "$(sshkeyname "$fqdn" "rsa" initrd)"
        "$(sshkeyname "$fqdn" "ed25519" initrd)"
    )
    for file in "${files_to_copy[@]}"; do
        scp \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -i "$identityfile" \
            "$file" \
            "root@${ipaddr}:/mnt/etc/secrets/initrd"
    done

    serverInfo="$(ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -i "$identityfile" \
        "root@${ipaddr}" \
        cat "/root/${name}.json")"

    addserverinfo "$fqdn" "$serverInfo"

    log "Running install for $fqdn"
    ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -i "$identityfile" \
        "root@${ipaddr}" \
        nixos-install --no-root-passwd

    log "Powering off $fqdn after install"
    # poweroff can cause the SSH tunnel to exit with code 255 if sshd
    # terminates before our tunnel.
    # Use || true to override the ssh exit code.
    ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -i "$identityfile" \
        "root@${ipaddr}" \
        poweroff || true

    sleep 5

    log "Booting $fqdn to new system"
    hcloud server poweron "$id"
    unlock "$fqdn" "$lukskey" "$identityfile"
}


function destroyserver() {
    local fqdn="$1"
    local ipaddr=
    local wireguardIp=
    local CONFIRM=
    local name=
    local id=
    local volumes=
    local volumeCount=
    local volumeid=
    local volumename=

    read -r -n 4 -p "This will completely destroy $fqdn and all data it contains. Type upper case YES to confirm" CONFIRM

    if [[ "$CONFIRM" != "YES" ]]; then
        error "Aborting"
    fi

    name="$(fqdn2name "$fqdn")"
    id="$(hcloudObjectId server "$name")"

    volumes="$(getServerInfo "$fqdn" .volumes)"
    volumeCount="$(echo "$volumes" | jq '. | length')"

    if [[ "$volumeCount" -gt 0 ]]; then
        volumename="${name}-data"
        volumeid="$(hcloudObjectId volume "$volumename")"
        fqdnlabel="$(hcloud volume describe "$volumeid" -ojson | jq -r '.labels["fqdn"]')"

        if [[ "$fqdnlabel" != "$fqdn" ]]; then
            error "Volume $volumename ($volumeid): FQDN $fqdn does not match label $fqdnlabel"
        fi
    fi

    hcloud server poweroff "$id"
    ipaddr="$(hcloudServerIP "$fqdn")"
    wireguardIp="$(getServerInfo "$fqdn" ".ipv4.wireguard.address")"

    if [[ "$volumeCount" -gt 0 ]]; then
        hcloud volume detach "$volumeid"
        read -r -n 4 -p "Really delete $fqdn data volume? Type upper case YES to confirm" CONFIRM
        if [[ "$CONFIRM" == "YES" ]]; then
            hcloud volume delete "$volumeid"
        else
            log "Not deleting the data volume for $fqdn."
        fi
    fi

    hcloud server delete "$id"

    rm -rf "$DIR/hosts/${fqdn}"

    delknownhosts "$fqdn" "$ipaddr" "$wireguardIp" "$DIR/ssh/ssh_known_hosts.initrd"
    delknownhosts "$fqdn" "$ipaddr" "$wireguardIp" "$DIR/ssh/ssh_known_hosts"

    python "$DIR/bin/update-dns.py" delete-host "$fqdn" 1>&2
}
