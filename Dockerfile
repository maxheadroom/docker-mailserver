FROM ubuntu:14.04
MAINTAINER Falko Zurell
ENV mailboxuser maxheadroom
ENV mailboxpassword maxheadroom
# Packages
RUN apt-get update -q --fix-missing
RUN apt-get -y upgrade
RUN DEBIAN_FRONTEND=noninteractive apt-get -y install vim postfix sasl2-bin  \
    cyrus-admin cyrus-common cyrus-caldav cyrus-clients cyrus-doc cyrus-murder procmail supervisor gamin amavisd-new spamassassin clamav clamav-daemon libnet-dns-perl libmail-spf-perl \
    pyzor razor arj bzip2 cabextract cpio file gzip nomarch p7zip pax unzip zip zoo rsyslog mailutils netcat \
    opendkim opendkim-tools opendmarc curl fail2ban git augeas-lenses dialog libaugeas0 libexpat1-dev libffi-dev libpython-dev \
    libpython2.7-dev libssl-dev python-dev python-setuptools python-virtualenv python2.7-dev zlib1g-dev
# RUN apt-get autoclean && rm -rf /var/lib/apt/lists/*

# Configures Saslauthd
RUN rm -rf /var/run/saslauthd && ln -s /var/spool/postfix/var/run/saslauthd /var/run/saslauthd
RUN adduser postfix sasl
RUN echo 'NAME="saslauthd"\nSTART=yes\nMECHANISMS="sasldb"\nTHREADS=0\nPWDIR=/var/spool/postfix/var/run/saslauthd\nPIDFILE="${PWDIR}/saslauthd.pid"\nOPTIONS="-n 0 -c -m /var/spool/postfix/var/run/saslauthd"' > /etc/default/saslauthd

# Configure Cyrus IMAPD

# set up the saslauthd accounts (complication: the host name changes all the time!)
# -u cyrus ensures the account is set up for the hostname cyrus
# cyrus is the account we need to run the cyradm commands
RUN echo ${mailboxpassword} | saslpasswd2 -p -u cyrus -c ${mailboxuser}
RUN echo "password" | saslpasswd2 -p -u cyrus -c cyrus
RUN chgrp mail /etc/sasldb2
RUN chsh -s /bin/bash cyrus
RUN addgroup lmtp
RUN adduser postfix lmtp
RUN adduser postfix mail
RUN adduser cyrus mail

# Set up the mailboxes by starting the cyrus imap daemon, calling up cyradm
# and running the create mailbox commands.

# Step 1: set up a sasl password valid under the build hostname (no -u param).
# Since sasl cares about the hostname the validation doesn't work on the above
# passwords with the -u cyrus hostname.

RUN echo "password" | saslpasswd2 -p -c cyrus

RUN sed -i -r 's/#admins: cyrus/admins: cyrus/g' /etc/imapd.conf
RUN sed -i -r 's/unixhierarchysep: no/unixhierarchysep: yes/g' /etc/imapd.conf
RUN sed -i -r 's/allowplaintext: yes/allowplaintext: no/g' /etc/imapd.conf
RUN sed -i -r 's/#virtdomains: userid/virtdomains: yes/g' /etc/imapd.conf
RUN sed -i -r 's/sasl_pwcheck_method: auxprop/sasl_pwcheck_method: saslauthd/g' /etc/imapd.conf
RUN postconf -e "virtual_transport = lmtp:unix:/var/run/cyrus/socket/lmtp"

# Enables Spamassassin and CRON updates
RUN sed -i -r 's/^(CRON|ENABLED)=0/\1=1/g' /etc/default/spamassassin

# Enables Amavis
RUN sed -i -r 's/#(@|   \\%)bypass/\1bypass/g' /etc/amavis/conf.d/15-content_filter_mode
RUN adduser clamav amavis
RUN adduser amavis clamav
RUN useradd -u 5000 -d /home/docker -s /bin/bash -p $(echo docker | openssl passwd -1 -stdin) docker

# Enables Clamav
RUN chmod 644 /etc/clamav/freshclam.conf
RUN (crontab -l ; echo "0 1 * * * /usr/bin/freshclam --quiet") | sort - | uniq - | crontab -
RUN freshclam

# Configure DKIM (opendkim)
RUN mkdir -p /etc/opendkim/keys
ADD postfix/TrustedHosts /etc/opendkim/TrustedHosts
# DKIM config files
ADD postfix/opendkim.conf /etc/opendkim.conf
ADD postfix/default-opendkim /etc/default/opendkim

# Configure DMARC (opendmarc)
ADD postfix/opendmarc.conf /etc/opendmarc.conf
ADD postfix/default-opendmarc /etc/default/opendmarc

# Configures Postfix
ADD postfix/main.cf /etc/postfix/main.cf
ADD postfix/master.cf /etc/postfix/master.cf
ADD postfix/sasl/smtpd.conf /etc/postfix/sasl/smtpd.conf
ADD bin/generate-ssl-certificate /usr/local/bin/generate-ssl-certificate
RUN chmod +x /usr/local/bin/generate-ssl-certificate


# get LetsEncrypt
WORKDIR /root
RUN git clone https://github.com/letsencrypt/letsencrypt
RUN cd /root/letsencrypt
RUN /root/letsencrypt/letsencrypt-auto --os-packages-only
# Get LetsEncrypt signed certificate
RUN curl https://letsencrypt.org/certs/lets-encrypt-x1-cross-signed.pem > /etc/ssl/certs/lets-encrypt-x1-cross-signed.pem
RUN curl https://letsencrypt.org/certs/lets-encrypt-x2-cross-signed.pem > /etc/ssl/certs/lets-encrypt-x2-cross-signed.pem

# Start-mailserver script
ADD start-mailserver.sh /usr/local/bin/start-mailserver.sh
RUN chmod +x /usr/local/bin/start-mailserver.sh

# SMTP ports
EXPOSE  25
EXPOSE  587

# IMAP ports
EXPOSE  143
EXPOSE  993

# POP3 ports
EXPOSE  110
EXPOSE  995

CMD /usr/local/bin/start-mailserver.sh
