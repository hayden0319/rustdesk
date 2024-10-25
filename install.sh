#!/bin/bash

# Get user options
while getopts i:-: option; do
    case "${option}" in
        -)
            case "${OPTARG}" in
                help)
                    help="true";;
                resolveip)
                    resolveip="true";;
                resolvedns)
                    val="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 ))
                    resolvedns=${val};;
                install-http)
                    http="true";;
                skip-http)
                    http="false";;
            esac;;
        i) resolveip="true";;
    esac
done

function displayhelp() {
    if [[ ! -z $help ]]; then
        echo 'usage: install.sh --resolveip --resolvedns "fqdn"'
        echo "options:"
        echo "--resolveip    Use IP for server name.  Cannot use in combination with --resolvedns or -d"
        echo '--resolvedns "fqdn"    Use FQDN for server name.  Cannot use in combination with --resolveip or -i'
        echo "--install-http    Install http server to host installation scripts.  Cannot use in combination with --skip-http or -n"
        echo "--skip-http    Skip installation of http server.  Cannot use in combination with --install-http or -h"
        exit 0
    fi
}
displayhelp
# Get Username
uname=$(whoami)
gname=$(id -gn ${uname})
admintoken=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c16)

ARCH=$(uname -m)

# identify OS
if [ -f /etc/os-release ]; then
    # freedesktop.org and systemd
    . /etc/os-release
    OS=$NAME
    VER=$VERSION_ID

    UPSTREAM_ID=${ID_LIKE,,}

    # Fallback to ID_LIKE if ID was not 'ubuntu' or 'debian'
    if [ "${UPSTREAM_ID}" != "debian" ] && [ "${UPSTREAM_ID}" != "ubuntu" ]; then
        UPSTREAM_ID="$(echo ${ID_LIKE,,} | sed s/\"//g | cut -d' ' -f1)"
    fi


elif type lsb_release >/dev/null 2>&1; then
    # linuxbase.org
    OS=$(lsb_release -si)
    VER=$(lsb_release -sr)
elif [ -f /etc/lsb-release ]; then
    # For some versions of Debian/Ubuntu without lsb_release command
    . /etc/lsb-release
    OS=$DISTRIB_ID
    VER=$DISTRIB_RELEASE
elif [ -f /etc/debian_version ]; then
    # Older Debian/Ubuntu/etc.
    OS=Debian
    VER=$(cat /etc/debian_version)
elif [ -f /etc/SuSe-release ]; then
    # Older SuSE/etc.
    OS=SuSE
    VER=$(cat /etc/SuSe-release)
elif [ -f /etc/redhat-release ]; then
    # Older Red Hat, CentOS, etc.
    OS=RedHat
    VER=$(cat /etc/redhat-release)
else
    # Fall back to uname, e.g. "Linux <version>", also works for BSD, etc.
    OS=$(uname -s)
    VER=$(uname -r)
fi


# output debugging info if $DEBUG set
if [ "$DEBUG" = "true" ]; then
    echo "OS: $OS"
    echo "VER: $VER"
    echo "UPSTREAM_ID: $UPSTREAM_ID"
    exit 0
fi

# Setup prereqs for server
# common named prereqs
PREREQ="curl wget unzip tar"
PREREQDEB="dnsutils"
PREREQRPM="bind-utils"
PREREQARCH="bind"

echo "Installing prerequisites"
if [ "${ID}" = "debian" ] || [ "$OS" = "Ubuntu" ] || [ "$OS" = "Debian" ]  || [ "${UPSTREAM_ID}" = "ubuntu" ] || [ "${UPSTREAM_ID}" = "debian" ]; then
    sudo apt-get update
    sudo apt-get install -y  ${PREREQ} ${PREREQDEB} # git
elif [ "$OS" = "CentOS" ] || [ "$OS" = "RedHat" ]   || [ "${UPSTREAM_ID}" = "rhel" ] ; then
# opensuse 15.4 fails to run the relay service and hangs waiting for it
# needs more work before it can be enabled
# || [ "${UPSTREAM_ID}" = "suse" ]
    sudo yum update -y
    sudo yum install -y  ${PREREQ} ${PREREQRPM} # git
elif [ "${ID}" = "arch" ] || [ "${UPSTREAM_ID}" = "arch" ]; then
    sudo pacman -Syu
    sudo pacman -S ${PREREQ} ${PREREQARCH}
else
    echo "Unsupported OS"
    # give them the option to continue
    echo -n "Would you like to continue? Dependencies may not be satisfied... [y/n] "
    read continue_no_dependencies
    if [ $continue_no_dependencies == "y" ]; then
        echo "Continuing..."
    elif [ $continue_no_dependencies != "n" ]; then
        echo "Invalid answer, exiting."
	exit 1
    else
        exit 1
    fi
fi

# Choice for DNS or IP
if [[ -z "$resolveip" && -z "$resolvedns" ]]; then
    PS3='Choose your preferred connection method: auto-resolve current WAN IP or enter your DNS/Domain:'
    WAN=("IP" "DNS/Domain")
    select WANOPT in "${WAN[@]}"; do
    case $WANOPT in
    "IP")
    wanip=$(dig @resolver4.opendns.com myip.opendns.com +short)
    break
    ;;

    "DNS/Domain")
    echo -ne "Enter your preferred domain/dns address ${NC}: "
    read wanip
    #check wanip is valid domain
    if ! [[ $wanip =~ ^[a-zA-Z0-9]+([a-zA-Z0-9.-]*[a-zA-Z0-9]+)?$ ]]; then
        echo -e "${RED}Invalid domain/dns address${NC}"
        exit 1
    fi
    break
    ;;
    *) echo "invalid option $REPLY";;
    esac
    done
elif [[ ! -z "$resolveip" && ! -z "$resolvedns" ]]; then
    echo -e "\nERROR: You cannot use both --resolveip & --resolvedns options simultaneously"
    exit 1
elif [[ ! -z "$resolveip" && -z "$resolvedns" ]]; then
    wanip=$(dig @resolver4.opendns.com myip.opendns.com +short)
elif [[ -z "$resolveip" && ! -z "$resolvedns" ]]; then
    wanip="$resolvedns"
    if ! [[ $wanip =~ ^[a-zA-Z0-9]+([a-zA-Z0-9.-]*[a-zA-Z0-9]+)?$ ]]; then
        echo -e "${RED}Invalid domain/dns address${NC}"
        exit 1
    fi
fi

# Make Folder /opt/rustdesk/
if [ ! -d "/opt/rustdesk" ]; then
    echo "Creating /opt/rustdesk"
    sudo mkdir -p /opt/rustdesk/
fi
sudo chown "${uname}" -R /opt/rustdesk
cd /opt/rustdesk/ || exit 1


#Download latest version of Rustdesk
RDLATEST=$(curl https://api.github.com/repos/rustdesk/rustdesk-server/releases/latest -s | grep "tag_name" | awk -F'"' '{print $4}')

echo "Installing Rustdesk Server"
if [ "${ARCH}" = "x86_64" ] ; then
wget "https://github.com/rustdesk/rustdesk-server/releases/download/${RDLATEST}/rustdesk-server-linux-amd64.zip"
unzip rustdesk-server-linux-amd64.zip
mv amd64/* /opt/rustdesk/
elif [ "${ARCH}" = "armv7l" ] ; then
wget "https://github.com/rustdesk/rustdesk-server/releases/download/${RDLATEST}/rustdesk-server-linux-armv7.zip"
unzip rustdesk-server-linux-armv7.zip
mv armv7/* /opt/rustdesk/
elif [ "${ARCH}" = "aarch64" ] ; then
wget "https://github.com/rustdesk/rustdesk-server/releases/download/${RDLATEST}/rustdesk-server-linux-arm64v8.zip"
unzip rustdesk-server-linux-arm64v8.zip
mv arm64v8/* /opt/rustdesk/
fi

chmod +x /opt/rustdesk/hbbs
chmod +x /opt/rustdesk/hbbr


# Make Folder /var/log/rustdesk/
if [ ! -d "/var/log/rustdesk" ]; then
    echo "Creating /var/log/rustdesk"
    sudo mkdir -p /var/log/rustdesk/
fi
sudo chown "${uname}" -R /var/log/rustdesk/

# Setup Systemd to launch hbbs
rustdesksignal="$(cat << EOF
[Unit]
Description=Rustdesk Signal Server
# Other configuration lines
EOF
)"
