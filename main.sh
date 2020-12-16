#!/bin/bash
###########################################################
# pterodactyl v0.7.19
# Copyright Valkam 2019-2021
#
# https://github.com/valkam08/pterodactyl-installer
###########################################################

# check if user is root or not
if [[ $EUID -ne 0 ]]; then
  echo "* This script must be executed with root privileges (sudo)." 1>&2
  exit 1
fi

# check for curl
CURLPATH="$(which curl)"
if [ -z "$CURLPATH" ]; then
    echo "* curl is required in order for this script to work."
    echo "* install using apt on Debian/Ubuntu or yum on CentOS"
    exit 1
fi

# check for python
PYTHONPATH="$(which python)"
if [ -z "$PYTHONPATH" ]; then
    echo "* python is required in order for this script to work."
    echo "* install using apt on Debian/Ubuntu or yum on CentOS"
    exit 1
fi

# variables
WEBSERVER="apache2"
OS="debian" # can
FQDN="pterodactyl.panel"

# default MySQL credentials
MYSQL_DB="pterodactyl"
MYSQL_USER="pterodactyl"
MYSQL_PASSWORD="somePassword"

# DL urls
PANEL_URL="https://github.com/pterodactyl/panel/releases/download/v0.7.19/panel.tar.gz"
CONFIGS_URL="https://raw.githubusercontent.com/valkam08/pterodactyl-installer/master/configs"

# paths
SOURCES_PATH="/etc/apt/sources.list"

# visual functions
function print_error {
  COLOR_RED='\033[0;31m'
  COLOR_NC='\033[0m'

  echo ""
  echo -e "* ${COLOR_RED}ERROR${COLOR_NC}: $1"
  echo ""
}

function print_brake {
  for ((n=0;n<$1;n++));
    do
      echo -n "#"
    done
    echo ""
}

# other functions
function detect_distro {
  echo "$(python -c 'import platform ; print platform.dist()[0]')" | awk '{print tolower($0)}'
}

function detect_os_version {
  echo "$(python -c 'import platform ; print platform.dist()[1].split(".")[0]')"
}

function check_os_comp {
  if [ "$OS" == "ubuntu" ]; then
    if [ "$OS_VERSION" == "18" ]; then
      SUPPORTED=true
    elif [ "$OS_VERSION" == "20" ]; then
      SUPPORTED=true
    else
      SUPPORTED=false
    fi
  elif [ "$OS" == "debian" ]; then
    if [ "$OS_VERSION" == "9" ]; then
      SUPPORTED=true
    elif [ "$OS_VERSION" == "10" ]; then
      SUPPORTED=true
    else
      SUPPORTED=false
    fi
  elif [ "$OS" == "centos" ]; then
    if [ "$OS_VERSION" == "7" ]; then
      SUPPORTED=true
    elif [ "$OS_VERSION" == "8" ]; then
      SUPPORTED=true
    else
      SUPPORTED=false
    fi
  else
    SUPPORTED=true
  fi

  # exit if not supported
  if [ "$SUPPORTED" == true ]; then
    echo "* $OS $OS_VERSION is supported."
  else
    echo "* $OS $OS_VERSION is not supported"
    print_error "Unsupported OS"
    exit 1
  fi
}

#################################
## main installation functions ##
#################################

function install_composer {
  echo "* Installing composer.."
  curl -sS https://getcomposer.org/installer | sudo php -- --install-dir=/usr/local/bin --filename=composer --version=1.10.16
  echo "* Composer installed!"
}

function ptdl_dl {
  echo "* Downloading pterodactyl panel files .. "
  mkdir -p /var/www/pterodactyl
  cd /var/www/pterodactyl

  curl -Lo panel.tar.gz $PANEL_URL
  tar -xzvf panel.tar.gz
  chmod -R 755 storage/* bootstrap/cache/

  cp .env.example .env
  composer install --no-dev --optimize-autoloader

  php artisan key:generate --force
  echo "* Downloaded pterodactyl panel files & installed composer dependencies!"
}

function configure {
  print_brake 88
  echo "* Please follow the steps below. The installer will ask you for configuration details."
  print_brake 88
  echo ""
  php artisan p:environment:setup

  print_brake 67
  echo "* The installer will now ask you for MySQL database credentials."
  print_brake 67
  echo ""
  php artisan p:environment:database

  print_brake 70
  echo "* The installer will now ask you for mail setup / mail credentials."
  print_brake 70
  echo ""
  php artisan p:environment:mail

  # configures database
  php artisan migrate --seed

  echo "* The installer will now ask you to create the inital admin user account."
  php artisan p:user:make

  # set folder permissions now
  set_folder_permissions
}

# set the correct folder permissions depending on OS and webserver
function set_folder_permissions {
  # if os is ubuntu or debian, we do this
  if [ "$OS" == "debian" ] || [ "$OS" == "ubuntu" ]; then
    chown -R www-data:www-data *
  elif [ "$OS" == "centos" ] && [ "$WEBSERVER" == "nginx" ]; then
    chown -R nginx:nginx *
  elif [ "$OS" == "centos" ] && [ "$WEBSERVER" == "apache2" ]; then
    chown -R apache:apache *
  else
    print_error "Invalid webserver and OS setup."
    exit 1
  fi
}

# insert cronjob
function insert_cronjob {
  echo "* Installing cronjob.. "
  crontab -l | { cat; echo "* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1"; } | crontab -
  echo "* Cronjob installed!"
}

function install_pteroq {
  echo "* Installing pteroq service.."

  curl -o /etc/systemd/system/pteroq.service $CONFIGS_URL/pteroq.service
  systemctl enable pteroq.service
  systemctl start pteroq

  echo "* Installed pteroq!"
}

function create_database {
  if [ "$OS" == "centos" ]; then
    mysql_secure_installation
  fi

  echo "* Creating MySQL database & user.."
  echo "* The script should have asked you to set the MySQL root password earlier (not to be confused with the pterodactyl database user password)"
  echo "* MySQL will now ask you to enter the password before each command."

  echo "* Performing MySQL queries.."

  echo "* Create MySQL user."
  mysql -u root -p -e "CREATE USER '${MYSQL_USER}'@'127.0.0.1' IDENTIFIED BY '${MYSQL_PASSWORD}';"

  echo "* Create database."
  mysql -u root -p -e "CREATE DATABASE ${MYSQL_DB};"

  echo "* Grant privileges."
  mysql -u root -p -e "GRANT ALL PRIVILEGES ON ${MYSQL_DB}.* TO '${MYSQL_USER}'@'127.0.0.1' WITH GRANT OPTION;"

  echo "* Flush privileges."
  mysql -u root -p -e "FLUSH PRIVILEGES;"

  echo "* MySQL database created & configured!"
}

##################################
# OS specific install functions ##
##################################

function apt_update {
  apt update -y && apt upgrade -y
}

function ubuntu20_dep {
  echo "* Installing dependencies for Ubuntu 18.."

  # Add "add-apt-repository" command
  apt -y install software-properties-common

  # Add additional repositories for PHP, Redis, and MariaDB
  curl -sS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | sudo bash

  # Update repositories list
  apt update

  # Install Dependencies

  if [ "$WEBSERVER" == "nginx" ]; then
  	apt -y install php7.4 php7.4-{cli,gd,mysql,pdo,mbstring,tokenizer,bcmath,xml,fpm,curl,zip} mariadb-server nginx curl tar unzip zip git
  elif [ "$WEBSERVER" == "apache2" ]; then
  	apt -y install php7.4 php7.4-{cli,gd,mysql,pdo,mbstring,tokenizer,bcmath,xml,fpm,curl,zip} mariadb-server apache2 curl tar unzip zip git
  else
    print_error "Invalid webserver."
    exit 1
  fi

  echo "* Dependencies for Ubuntu installed!"
}

function ubuntu18_dep {
  echo "* Installing dependencies for Ubuntu 18.."

  # Add "add-apt-repository" command
  apt -y install software-properties-common

  # Add additional repositories for PHP, Redis, and MariaDBInstall Dependencies
  sudo add-apt-repository ppa:ondrej/php
  curl -sS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | sudo bash

  # Update repositories list
  apt update

  # Install Dependencies

  if [ "$WEBSERVER" == "nginx" ]; then
  	apt -y install php7.4 php7.4-{cli,gd,mysql,pdo,mbstring,tokenizer,bcmath,xml,fpm,curl,zip} mariadb-server nginx curl tar unzip zip git
  elif [ "$WEBSERVER" == "apache2" ]; then
  	apt -y install php7.4 php7.4-{cli,gd,mysql,pdo,mbstring,tokenizer,bcmath,xml,fpm,curl,zip} mariadb-server apache2 curl tar unzip zip git
  else
    print_error "Invalid webserver."
    exit 1
  fi

  echo "* Dependencies for Ubuntu installed!"
}

function debian_dep {
  echo "* Installing dependencies for Debian.."

  # MariaDB need dirmngr
  apt -y install dirmngr

  # install PHP 7.2 using Sury's rep instead of PPA
  # this guide shows how: https://vilhelmprytz.se/2018/08/22/install-php72-on-Debian-8-and-9.html 
  apt -y install software-properties-common curl apt-transport-https ca-certificates gnupg lsb-release
  sudo wget -O /etc/apt/trusted.gpg.d/php.gpg https://packages.sury.org/php/apt.gpg
  echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" | sudo tee /etc/apt/sources.list.d/php.list

  # redis-server is not installed using the PPA, as it's already available in the Debian repo

  # Install MariaDb
  curl -sS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | sudo bash

  # Update repositories list
  apt update

  # Install Dependencies
  if [ "$WEBSERVER" == "nginx" ]; then
  	apt -y install php7.4 php7.4-{cli,gd,mysql,pdo,mbstring,tokenizer,bcmath,xml,fpm,curl,zip} mariadb-server nginx curl tar unzip zip git
  elif [ "$WEBSERVER" == "apache2" ]; then
  	apt -y install php7.4 php7.4-{cli,gd,mysql,pdo,mbstring,tokenizer,bcmath,xml,fpm,curl,zip} mariadb-server apache2 curl tar unzip zip git
    sudo a2enmod proxy_fcgi setenvif
    sudo a2enmod rewrite
    sudo a2enconf php7.4-fpm
    systemctl restart apache2
  else
    print_error "Invalid webserver."
    exit 1
  fi

  echo "* Dependencies for Debian installed!"
}

function centos_dep {
  echo "* Installing dependencies for CentOS.."

  # update first
  yum update -y

  # install php7.2
  yum install -y epel-release https://centos7.iuscommunity.org/ius-release.rpm
  yum -y install yum-utils
  yum update -y

  # Install MariaDB
  curl -sS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | sudo bash

  # install dependencies
  if [ "$WEBSERVER" == "nginx" ]; then
  	yum -y install install php72u-php php72u-common php72u-fpm php72u-cli php72u-json php72u-mysqlnd php72u-mcrypt php72u-gd php72u-mbstring php72u-pdo php72u-zip php72u-bcmath php72u-dom php72u-opcache mariadb-server nginx curl tar unzip git redis
  elif [ "$WEBSERVER" == "apache2" ]; then
  	yum -y install install php72u-php php72u-common php72u-fpm php72u-cli php72u-json php72u-mysqlnd php72u-mcrypt php72u-gd php72u-mbstring php72u-pdo php72u-zip php72u-bcmath php72u-dom php72u-opcache mariadb-server apache2 curl tar unzip git redis
  else
    print_error "Invalid webserver."
    exit 1
  fi

  # enable services
  systemctl enable mariadb
  systemctl enable redis
  systemctl enable php-fpm.service
  systemctl start mariadb
  systemctl start redis
  systemctl start php-fpm.service


  echo "* Dependencies for CentOS installed!"
}

#################################
## OTHER OS SPECIFIC FUNCTIONS ##
#################################

function ubuntu_universedep {
  if grep -q universe "$SOURCES_PATH"; then
    # even if it detects it as already existent, we'll still run the apt command to make sure
    add-apt-repository universe
    echo "* Ubuntu universe repo already exists."
  else
    add-apt-repository universe
  fi
}


#######################################
## WEBSERVER CONFIGURATION FUNCTIONS ##
#######################################

function configure_nginx {
  echo "* Configuring nginx .."

  DL_FILE="nginx.conf"

  if [ "$OS" == "centos" ]; then
      # remove default config
      rm -rf /etc/nginx/conf.d/default

      # download new config
      curl -o /etc/nginx/conf.d/pterodactyl.conf $CONFIGS_URL/$DL_FILE

      # replace all <domain> places with the correct domain
      sed -i -e "s/<domain>/${FQDN}/g" /etc/nginx/conf.d/pterodactyl.conf
  else
      # remove default config
      rm -rf /etc/nginx/sites-enabled/default

      # download new config
      curl -o /etc/nginx/sites-available/pterodactyl.conf $CONFIGS_URL/$DL_FILE

      # replace all <domain> places with the correct domain
      sed -i -e "s/<domain>/${FQDN}/g" /etc/nginx/sites-available/pterodactyl.conf

      # enable pterodactyl
      sudo ln -s /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
  fi

  # restart nginx
  systemctl restart nginx
  echo "* nginx configured!"
}

function configure_apache {
  echo "* Configuring apache2 .."
    
  DL_FILE="apache2.conf"

  if [ "$OS" == "centos" ]; then
      # remove default config
      rm -rf /etc/apache2/conf.d/default

      # download new config
      curl -o /etc/apache2/conf.d/pterodactyl.conf $CONFIGS_URL/$DL_FILE

      # replace all <domain> places with the correct domain
      sed -i -e "s/<domain>/${FQDN}/g" /etc/apache2/conf.d/pterodactyl.conf
  else
      # remove default config
      rm -rf /etc/apache2/sites-available/000-default.conf
      rm -rf /etc/apache2/sites-enabled/000-default.conf

      # download new config
      curl -o /etc/apache2/sites-available/pterodactyl.conf $CONFIGS_URL/$DL_FILE

      # replace all <domain> places with the correct domain
      sed -i -e "s/<domain>/${FQDN}/g" /etc/apache2/sites-available/pterodactyl.conf

      # enable pterodactyl
      sudo ln -s /etc/apache2/sites-available/pterodactyl.conf /etc/apache2/sites-enabled/pterodactyl.conf
  fi

  # restart apache2
  systemctl restart apache2
  echo "* apache2 configured!"
}

####################
## MAIN FUNCTIONS ##
####################

function perform_install {
  echo "* Starting installation.. this might take a while!"
  # do different things depending on OS
  if [ "$OS" == "ubuntu" ]; then
    ubuntu_universedep
    apt_update
    # different dependencies depending on if it's 18 or 16
    if [ "$OS_VERSION" == "18" ]; then
      ubuntu18_dep
    elif [ "$OS_VERSION" == "20" ]; then
      ubuntu20_dep
    else
      print_error "Unsupported version of Ubuntu."
      exit 1
    fi
    install_composer
    ptdl_dl
    create_database
    configure
    insert_cronjob
    install_pteroq
  elif [ "$OS" == "debian" ]; then
    apt_update
    debian_dep
    install_composer
    ptdl_dl
    create_database
    configure
    insert_cronjob
    install_pteroq
  elif [ "$OS" == "centos" ]; then
    centos_dep
    install_composer
    ptdl_dl
    create_database
    configure
    insert_cronjob
    install_pteroq
  else
    # exit
    print_error "OS not supported."
    exit 1
  fi

  # perform webserver configuration
  if [ "$WEBSERVER" == "nginx" ]; then
    configure_nginx
  elif [ "$WEBSERVER" == "apache2" ]; then
    configure_apache
  else
    print_error "Invalid webserver."
    exit 1
  fi

}

function main {
  print_brake 40
  echo "* Pterodactyl panel installation script "
  echo "* Detecting operating system."
  OS=$(detect_distro);
  OS_VERSION=$(detect_os_version)
  echo "* Running $OS version $OS_VERSION."
  print_brake 40

  # checks if the system is compatible with this installation script
  check_os_comp

  echo "* [1] - nginx"
  echo "* [2] - apache2"

  echo ""

  echo -n "* Select webserver to install pterodactyl panel with: "
  read WEBSERVER_INPUT

  if [ "$WEBSERVER_INPUT" == "1" ]; then
    WEBSERVER="nginx"
  elif [ "$WEBSERVER_INPUT" == "2" ]; then
    WEBSERVER="apache2"
  fi

  # set database credentials
  print_brake 72
  echo "* Database configuration."
  echo ""
  echo "* This will be the credentials used for commuication between the MySQL"
  echo "* database and the panel. You do not need to create the database"
  echo "* before running this script, the script will do that for you."
  echo ""

  echo -n "* Database name (panel): "
  read MYSQL_DB_INPUT

  if [ -z "$MYSQL_DB_INPUT" ]; then
    MYSQL_DB="panel"
  else
    MYSQL_DB=$MYSQL_DB_INPUT
  fi

  echo -n "* Username (pterodactyl): "
  read MYSQL_USER_INPUT

  if [ -z "$MYSQL_USER_INPUT" ]; then
    MYSQL_USER="pterodactyl"
  else
    MYSQL_USER=$MYSQL_USER_INPUT
  fi

  echo -n "* Password (use something strong): "
  read MYSQL_PASSWORD

  if [ -z "$MYSQL_PASSWORD" ]; then
    print_error "MySQL password cannot be empty"
    exit 1
  fi

  print_brake 72

  # set FQDN

  echo -n "* Set the FQDN of this panel (panel hostname): "
  read FQDN

  echo ""

  # confirm installation
  echo -e -n "\n* Inital configuration done. Do you wan't to continue with the installation? (y/n): "
  read CONFIRM
  if [ "$CONFIRM" == "y" ]; then
    perform_install
  elif [ "$CONFIRM" == "n" ]; then
    exit 0
  else
    # run welcome script again
    print_error "Invalid confirm. Will exit."
    exit 1
  fi

}

function goodbye {
  print_brake 62
  echo "* Pterodactyl Panel successfully installed @ $FQDN"
  echo ""
  echo "* Installation is using $WEBSERVER on $OS"
  print_brake 62

  exit 0
}

# start main function
main
goodbye
