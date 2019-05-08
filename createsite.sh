#!/bin/bash
# This file is meant to be run with sudo
# Example: sudo this-script.sh
#
# This script assumes that DNS has already been setup for this host, and that both 'domain.tld' and 'www.domain.tld' are configured

clear
read -p "Please enter new WordPress site domain  : " wpdir

# validate the domain name. if its good assign $wpdir as the directory name and $wpdom as the domain name
PATTERN="^(([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9\-]*[a-zA-Z0-9])\.)*([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9\-]*[A-Za-z0-9])$";
if [[ "$wpdir" =~ $PATTERN ]]; then
        wpdom=$wpdir
        wpdir=$(echo $wpdir | tr "." "_")
        wpdir=$(echo $wpdir | tr "-" "_")
else
        echo "invalid domain name"
        exit 1
fi

# setup the rest of the variables for the script to run
problem=0
sqlhost=#obfiscated-use-your-own-sqlhost
webroot=/var/www/$wpdir
webconf=/usr/local/nginx/sites-available/$wpdir
wpconf=$webroot/public_html/wp-config.php
username=${wpdir:0:32}
userpass=$(date +%N | sha256sum | tr -dc '[:alnum:]'; echo)
dbuser=wp_${wpdir:0:13}
dbase=wp_${wpdir:0:60}
dbuserpass=$(date +%N | sha256sum | tr -dc '[:alnum:]'; echo)

# look to see if the nginx configuration file, the web directory or the username exist already
if [ -f "$webconf" ];
then
        problem=1
        errmsg="Existing web configuration file: $webconf\n"
fi

if [ -d "$webroot" ];
then
        problem=1
        errmsg=$errmsg"Existing web root dir: $webroot\n"
fi

getent passwd $username  > /dev/null

if [ $? -eq 0 ];
then
        problem=1
        errmsg=$errmsg"Existing user: $username\n"
fi

if [ $problem -eq 1 ];
then
        echo "ERROR - Exiting Script"
        echo -e $errmsg
        exit 1
else

# Create the MySQL database. Error out if it can't connect or there's an error
mysql -u root -p --host=$sqlhost -e "CREATE DATABASE \`$dbase\`; CREATE USER '$dbuser'@'%' IDENTIFIED BY '$dbuserpass'; GRANT ALL ON \`$dbase\`.* TO '$dbuser'@'%';"

if [ $? != 0 ];
then
        echo "Bad Password or unknown failure on mySQL"
        echo "Exiting script . . ."
        exit 1
fi

# Create the local user account and group. Add the user to the group.
adduser $username --system --no-create-home --disabled-login > /dev/null
echo $username:$userpass | chpasswd
addgroup $username > /dev/null
usermod -a -G $username $username > /dev/null
usermod -a -G $username www-data > /dev/null
# make sure to add myself to the new group
usermod -a -G $username #obfiscated-use-your-own-name > /dev/null

# make the appropriate directories for webroot
mkdir $webroot
mkdir $webroot/logs
wget -N https://wordpress.org/latest.zip
cp -n latest.zip /var/www/
unzip /var/www/latest.zip -d $webroot > /dev/null
mv $webroot/wordpress/ $webroot/public_html
rm $webroot/public_html/wp-config-sample.php

# create the wp-config.php file and give it the appropriate information to connect to the MySQL DB
cat > $wpconf<<EOF
<?php
  define('DB_NAME', '${dbase}');
  define('DB_USER', '${dbuser}');
  define('DB_PASSWORD', '${dbuserpass}');
  define('DB_HOST', '${sqlhost}');
  define('DB_CHARSET', 'utf8');
  define('DB_COLLATE', '');

EOF
wget -qO- https://api.wordpress.org/secret-key/1.1/salt/ >> $wpconf
cat >> $wpconf<<EOF

\$table_prefix  = 'wp_';

define('WP_DEBUG', false);
define('WP_DEBUG_LOG', true);

if ( !defined('ABSPATH') )
        define('ABSPATH', dirname(__FILE__) . '/');

require_once(ABSPATH . 'wp-settings.php');
EOF

# setup the appropriate permissions for the webroot
# protect the wp-config.php file
chown -R $username:$username $webroot
chmod 0640 -R $webroot
chmod -R a+X $webroot
chmod 600 $webroot/public_html/wp-config.php

# setup the website to listen on TCP port 80. this will allow us to automatically
# have 'letsencrypt' validate the site and get certificates.
cp /usr/local/nginx/sites-available/template-no-ssl /usr/local/nginx/sites-available/${wpdir}-no-ssl
sed -i 's#%ROOT%#'${webroot}'/#g' /usr/local/nginx/sites-available/${wpdir}-no-ssl
sed -i 's#%SERVERNAME%#'${wpdom}'#g' /usr/local/nginx/sites-available/${wpdir}-no-ssl
ln -s /usr/local/nginx/sites-available/${wpdir}-no-ssl /usr/local/nginx/sites-enabled/${wpdir}-no-ssl.conf
service nginx reload

# now 'letsencrypt' will go do its thing
letsencrypt certonly -a webroot --webroot-path=${webroot}/public_html/ -d $wpdom -d www.$wpdom

# remove the non-SSL config from the site. put in place the real webconfig that will force SSL.
unlink /usr/local/nginx/sites-enabled/${wpdir}-no-ssl.conf
rm /usr/local/nginx/sites-available/${wpdir}-no-ssl
cp /usr/local/nginx/sites-available/template-yes-ssl /usr/local/nginx/sites-available/${wpdir}
sed -i 's#%ROOT%#'${webroot}'/#g' /usr/local/nginx/sites-available/${wpdir}
sed -i 's#%SERVERNAME%#'${wpdom}'#g' /usr/local/nginx/sites-available/${wpdir}
sed -i 's#%USERNAME%#'${username}'#g' /usr/local/nginx/sites-available/${wpdir}
ln -s /usr/local/nginx/sites-available/${wpdir} /usr/local/nginx/sites-enabled/${wpdir}.conf

# setup php for the site
cp /etc/php/7.0/fpm/sites-available/template /etc/php/7.0/fpm/sites-available/${wpdir}
sed -i 's#%USERNAME%#'${username}'#g' /etc/php/7.0/fpm/sites-available/${wpdir}
ln -s /etc/php/7.0/fpm/sites-available/${wpdir} /etc/php/7.0/fpm/pool.d/${wpdir}.conf

# Reload everything!
service php7.0-fpm restart
service nginx reload

fi
