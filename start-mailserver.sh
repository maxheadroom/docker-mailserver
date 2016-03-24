#!/bin/bash

die () {
  echo >&2 "$@"
  exit 1
}
# grant access to cyrus to local admin
echo "password" | saslpasswd2 -p -u `hostname` -c cyrus

# Cyrus IMAPD config
cp /tmp/cyrus/imapd.conf /etc/imapd.conf
cp /tmp/cyrus/cyrus.conf /etc/cyrus.conf
sed -i -r 's/#admins: cyrus/admins: cyrus/g' /etc/imapd.conf

if [ "$SMTP_ONLY" != 1 ]; then



/etc/init.d/cyrus-imapd start

# Fix Socket permission after daemon start
dpkg-statoverride --force --update --add cyrus lmtp 750 /var/run/cyrus/socket/lmtp

fi

if [ -f /tmp/postfix/accounts.cf ]; then
  echo "Regenerating postfix 'vmailbox' and 'virtual' for given users"
  echo "# WARNING: this file is auto-generated. Modify accounts.cf in postfix directory on host" > /etc/postfix/vmailbox

  # Checking that /tmp/postfix/accounts.cf ends with a newline
  sed -i -e '$a\' /tmp/postfix/accounts.cf

  # Creating users
  while IFS=$'|' read login pass
  do
    # Setting variables for better readability
    user=$(echo ${login} | cut -d @ -f1)
    domain=$(echo ${login} | cut -d @ -f2)
    # Let's go!
    echo "user '${user}' for domain '${domain}' with password '********'"
    echo "${login} ${domain}/${user}/" >> /etc/postfix/vmailbox
    # /usr/sbin/userdb ${login} set uid=5000 gid=5000 home=/var/mail/${domain}/${user} mail=/var/mail/${domain}/${user}
    # echo "${pass}" | userdbpw -md5 | userdb ${login} set systempw
    echo "${pass}" | saslpasswd2 -p -c -u ${domain} ${login}
    # Cyrus
    echo -e "createmailbox user/${user}@${domain}\nexit" | sudo -u cyrus -i cyradm --user cyrus -w password localhost
    echo ${domain} >> /tmp/vhost.tmp
  done < /tmp/postfix/accounts.cf
  # makeuserdb
else
  echo "==> Warning: '/tmp/postfix/accounts.cf' is not provided. No mail account created."
fi

if [ -f /tmp/postfix/virtual ]; then
  # Copying virtual file
  cp /tmp/postfix/virtual /etc/postfix/virtual
  while IFS=$' ' read from to
  do
    # Setting variables for better readability
    domain=$(echo ${from} | cut -d @ -f2)
    echo ${domain} >> /tmp/vhost.tmp
  done < /tmp/postfix/virtual
else
  echo "==> Warning: '/tmp/postfix/virtual' is not provided. No mail alias created."
fi

if [ -f /tmp/vhost.tmp ]; then
  cat /tmp/vhost.tmp | sort | uniq > /etc/postfix/vhost && rm /tmp/vhost.tmp
fi

echo "Postfix configurations"
touch /etc/postfix/vmailbox && postmap /etc/postfix/vmailbox
touch /etc/postfix/virtual && postmap /etc/postfix/virtual

postconf -e "virtual_transport = lmtp:unix:/var/run/cyrus/socket/lmtp"


# DKIM
grep -vE '^(\s*$|#)' /etc/postfix/vhost | while read domainname; do
  mkdir -p /etc/opendkim/keys/$domainname
  if [ ! -f "/etc/opendkim/keys/$domainname/mail.private" ]; then
    echo "Creating DKIM private key /etc/opendkim/keys/$domainname/mail.private"
    pushd /etc/opendkim/keys/$domainname
    opendkim-genkey --subdomains --domain=$domainname --selector=mail
    popd
    echo ""
    echo "DKIM PUBLIC KEY ################################################################"
    cat /etc/opendkim/keys/$domainname/mail.txt
    echo "################################################################################"
  fi
  # Write to KeyTable if necessary
  keytableentry="mail._domainkey.$domainname $domainname:mail:/etc/opendkim/keys/$domainname/mail.private"
  if [ ! -f "/etc/opendkim/KeyTable" ]; then
    echo "Creating DKIM KeyTable"
    echo "mail._domainkey.$domainname $domainname:mail:/etc/opendkim/keys/$domainname/mail.private" > /etc/opendkim/KeyTable
  else
    if ! grep -q "$keytableentry" "/etc/opendkim/KeyTable" ; then
      echo $keytableentry >> /etc/opendkim/KeyTable
    fi
  fi
  # Write to SigningTable if necessary
  signingtableentry="*@$domainname mail._domainkey.$domainname"
  if [ ! -f "/etc/opendkim/SigningTable" ]; then
    echo "Creating DKIM SigningTable"
    echo "*@$domainname mail._domainkey.$domainname" > /etc/opendkim/SigningTable
  else
    if ! grep -q "$signingtableentry" "/etc/opendkim/SigningTable" ; then
      echo $signingtableentry >> /etc/opendkim/SigningTable
    fi
  fi
done

echo "Changing permissions on /etc/opendkim"
# chown entire directory
chown -R opendkim:opendkim /etc/opendkim/
# And make sure permissions are right
chmod -R 0700 /etc/opendkim/keys/

# DMARC
# if ther is no AuthservID create it
if [ `cat /etc/opendmarc.conf | grep -w AuthservID | wc -l` -eq 0 ]; then
  echo "AuthservID $(hostname)" >> /etc/opendmarc.conf
fi
if [ `cat /etc/opendmarc.conf | grep -w TrustedAuthservIDs | wc -l` -eq 0 ]; then
  echo "TrustedAuthservIDs $(hostname)" >> /etc/opendmarc.conf
fi
if [ ! -f "/etc/opendmarc/ignore.hosts" ]; then
  mkdir -p /etc/opendmarc/
  echo "localhost" >> /etc/opendmarc/ignore.hosts
fi

# SSL Configuration
case $DMS_SSL in
  "letsencrypt" )
    # letsencrypt folders and files mounted in /etc/letsencrypt

      # Postfix configuration
      sed -i -r 's/smtpd_tls_cert_file=\/etc\/ssl\/certs\/ssl-cert-snakeoil.pem/smtpd_tls_cert_file=\/etc\/letsencrypt\/live\/'$(hostname)'\/fullchain.pem/g' /etc/postfix/main.cf
      sed -i -r 's/smtpd_tls_key_file=\/etc\/ssl\/private\/ssl-cert-snakeoil.key/smtpd_tls_key_file=\/etc\/letsencrypt\/live\/'$(hostname)'\/privkey.pem/g' /etc/postfix/main.cf

      # Courier configuration
      #cat "/etc/letsencrypt/live/$(hostname)/cert.pem" "/etc/letsencrypt/live/$(hostname)/chain.pem" "/etc/letsencrypt/live/$(hostname)/privkey.pem" > "/etc/letsencrypt/live/$(hostname)/combined.pem"
      # sed -i -r 's/TLS_CERTFILE=\/etc\/courier\/imapd.pem/TLS_CERTFILE=\/etc\/letsencrypt\/live\/'$(hostname)'\/combined.pem/g' /etc/courier/imapd-ssl
      # POP3 courier configuration
      # sed -i -r 's/POP3_TLS_REQUIRED=0/POP3_TLS_REQUIRED=1/g' /etc/courier/pop3d-ssl
      # sed -i -r 's/TLS_CERTFILE=\/etc\/courier\/pop3d.pem/TLS_CERTFILE=\/etc\/letsencrypt\/live\/'$(hostname)'\/combined.pem/g' /etc/courier/pop3d-ssl
      # needed to support gmail
      # sed -i -r 's/TLS_TRUSTCERTS=\/etc\/ssl\/certs/TLS_TRUSTCERTS=\/etc\/letsencrypt\/live\/'$(hostname)'\/fullchain.pem/g' /etc/courier/pop3d-ssl


      # Cyrus IMAPD configuration
      sed -i -r 's/#imap_tls_cert_file: \/etc\/ssl\/certs\/cyrus-imap.pem\/imap_tls_cert_file: \/etc\/letsencrypt\/live\/'$(hostname)'\/fullchain.pem/g' /etc/imapd.conf
      sed -i -r 's/#imap_tls_key_file: \/etc\/ssl\/private\/cyrus-imap.key/imap_tls_key_file: \/etc\/letsencrypt\/live\/'$(hostname)'\/privkey.pem/g' /etc/imapd.conf

      sed -i -r 's/#tls_cert_file: \/etc\/ssl\/certs\/ssl-cert-snakeoil.pem\/tls_cert_file: \/etc\/letsencrypt\/live\/'$(hostname)'\/fullchain.pem/g' /etc/imapd.conf
      sed -i -r 's/#tls_key_file: \/etc\/ssl\/private\/ssl-cert-snakeoil.key\/tls_key_file: \/etc\/letsencrypt\/live\/'$(hostname)'\/privkey.pem/g' /etc/imapd.conf



      echo "SSL configured with letsencrypt certificates"

    ;;

  "custom" )
    # Adding CA signed SSL certificate if provided in 'postfix/ssl' folder
    if [ -e "/tmp/postfix/ssl/$(hostname)-full.pem" ]; then
      echo "Adding $(hostname) SSL certificate"
      mkdir -p /etc/postfix/ssl
      cp "/tmp/postfix/ssl/$(hostname)-full.pem" /etc/postfix/ssl

      # Postfix configuration
      sed -i -r 's/smtpd_tls_cert_file=\/etc\/ssl\/certs\/ssl-cert-snakeoil.pem/smtpd_tls_cert_file=\/etc\/postfix\/ssl\/'$(hostname)'-full.pem/g' /etc/postfix/main.cf
      sed -i -r 's/smtpd_tls_key_file=\/etc\/ssl\/private\/ssl-cert-snakeoil.key/smtpd_tls_key_file=\/etc\/postfix\/ssl\/'$(hostname)'-full.pem/g' /etc/postfix/main.cf

      # Courier configuration
      sed -i -r 's/TLS_CERTFILE=\/etc\/courier\/imapd.pem/TLS_CERTFILE=\/etc\/postfix\/ssl\/'$(hostname)'-full.pem/g' /etc/courier/imapd-ssl

      # POP3 courier configuration
      sed -i -r 's/POP3_TLS_REQUIRED=0/POP3_TLS_REQUIRED=1/g' /etc/courier/pop3d-ssl
      sed -i -r 's/TLS_CERTFILE=\/etc\/courier\/pop3d.pem/TLS_CERTFILE=\/etc\/postfix\/ssl\/'$(hostname)'-full.pem/g' /etc/courier/pop3d-ssl

      echo "SSL configured with CA signed/custom certificates"

    fi
    ;;

  "self-signed" )
    # Adding self-signed SSL certificate if provided in 'postfix/ssl' folder
    if [ -e "/tmp/postfix/ssl/$(hostname)-cert.pem" ] \
    && [ -e "/tmp/postfix/ssl/$(hostname)-key.pem"  ] \
    && [ -e "/tmp/postfix/ssl/$(hostname)-combined.pem" ] \
    && [ -e "/tmp/postfix/ssl/demoCA/cacert.pem" ]; then
      echo "Adding $(hostname) SSL certificate"
      mkdir -p /etc/postfix/ssl
      cp "/tmp/postfix/ssl/$(hostname)-cert.pem" /etc/postfix/ssl
      cp "/tmp/postfix/ssl/$(hostname)-key.pem" /etc/postfix/ssl
      cp "/tmp/postfix/ssl/$(hostname)-combined.pem" /etc/postfix/ssl
      cp /tmp/postfix/ssl/demoCA/cacert.pem /etc/postfix/ssl

      # Postfix configuration
      sed -i -r 's/smtpd_tls_cert_file=\/etc\/ssl\/certs\/ssl-cert-snakeoil.pem/smtpd_tls_cert_file=\/etc\/postfix\/ssl\/'$(hostname)'-cert.pem/g' /etc/postfix/main.cf
      sed -i -r 's/smtpd_tls_key_file=\/etc\/ssl\/private\/ssl-cert-snakeoil.key/smtpd_tls_key_file=\/etc\/postfix\/ssl\/'$(hostname)'-key.pem/g' /etc/postfix/main.cf
      sed -i -r 's/#smtpd_tls_CAfile=/smtpd_tls_CAfile=\/etc\/postfix\/ssl\/cacert.pem/g' /etc/postfix/main.cf
      sed -i -r 's/#smtp_tls_CAfile=/smtp_tls_CAfile=\/etc\/postfix\/ssl\/cacert.pem/g' /etc/postfix/main.cf
      ln -s /etc/postfix/ssl/cacert.pem "/etc/ssl/certs/cacert-$(hostname).pem"

      # Courier configuration
      sed -i -r 's/TLS_CERTFILE=\/etc\/courier\/imapd.pem/TLS_CERTFILE=\/etc\/postfix\/ssl\/'$(hostname)'-combined.pem/g' /etc/courier/imapd-ssl

      # POP3 courier configuration
      sed -i -r 's/POP3_TLS_REQUIRED=0/POP3_TLS_REQUIRED=1/g' /etc/courier/pop3d-ssl
      sed -i -r 's/TLS_CERTFILE=\/etc\/courier\/pop3d.pem/TLS_CERTFILE=\/etc\/postfix\/ssl\/'$(hostname)'-combined.pem/g' /etc/courier/pop3d-ssl

      echo "SSL configured with self-signed/custom certificates"

    fi
    ;;

esac

echo "Fixing permissions"
chown -R 5000:5000 /var/mail
mkdir -p /var/log/clamav && chown -R clamav:root /var/log/clamav
chown postfix.sasl /etc/sasldb2

echo "Creating /etc/mailname"
echo $(hostname -d) > /etc/mailname

echo "Configuring Spamassassin"
SA_TAG=${SA_TAG:="2.0"} && sed -i -r 's/^\$sa_tag_level_deflt (.*);/\$sa_tag_level_deflt = '$SA_TAG';/g' /etc/amavis/conf.d/20-debian_defaults
SA_TAG2=${SA_TAG2:="6.31"} && sed -i -r 's/^\$sa_tag2_level_deflt (.*);/\$sa_tag2_level_deflt = '$SA_TAG2';/g' /etc/amavis/conf.d/20-debian_defaults
SA_KILL=${SA_KILL:="6.31"} && sed -i -r 's/^\$sa_kill_level_deflt (.*);/\$sa_kill_level_deflt = '$SA_KILL';/g' /etc/amavis/conf.d/20-debian_defaults
cp /tmp/spamassassin/rules.cf /etc/spamassassin/

echo "Configuring fail2ban"
# enable filters
perl -i -0pe 's/(\[postfix\]\n\n).*\n/\1enabled  = true\n/'     /etc/fail2ban/jail.conf
perl -i -0pe 's/(\[couriersmtp\]\n\n).*\n/\1enabled  = true\n/' /etc/fail2ban/jail.conf
perl -i -0pe 's/(\[courierauth\]\n\n).*\n/\1enabled  = true\n/' /etc/fail2ban/jail.conf
perl -i -0pe 's/(\[sasl\]\n\n).*\n/\1enabled  = true\n/'        /etc/fail2ban/jail.conf

# increase ban time and find time to 3h
sed -i "/^bantime *=/c\bantime = 10800"     /etc/fail2ban/jail.conf
sed -i "/^findtime *=/c\findtime = 10800"   /etc/fail2ban/jail.conf

# avoid warning on startup
echo "ignoreregex =" >> /etc/fail2ban/filter.d/postfix-sasl.conf


echo "Starting daemons"
cron
/etc/init.d/rsyslog start
/etc/init.d/saslauthd start


/etc/init.d/spamassassin start
/etc/init.d/clamav-daemon start
/etc/init.d/amavis start
/etc/init.d/opendkim start
/etc/init.d/opendmarc start
/etc/init.d/postfix start
/etc/init.d/fail2ban start

echo "Listing SASL users"
sasldblistusers2

echo "Listing Cyrus Mailboxes"
echo -e "lm\nexit" | sudo -u cyrus -i cyradm --user cyrus -w password localhost
echo "Starting..."
tail -f /var/log/mail.log
