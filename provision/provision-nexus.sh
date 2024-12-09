#!/bin/bash
set -euxo pipefail

nexus_domain=$(hostname --fqdn)

# use the local nexus user database.
config_authentication='nexus'
# OR use LDAP.
# NB this assumes you are running the Active Directory from https://github.com/rgl/windows-domain-controller-vagrant.
#config_authentication='ldap'


# install java.
# see https://help.sonatype.com/repomanager3/product-information/system-requirements#SystemRequirements-Java
apt-get install -y openjdk-17-jre-headless
apt-get install -y gnupg


# add the nexus user.
groupadd --system nexus
adduser \
    --system \
    --disabled-login \
    --no-create-home \
    --gecos '' \
    --ingroup nexus \
    --home /opt/nexus \
    nexus
install -d -o root -g nexus -m 750 /opt/nexus


# download and install nexus.
pushd /opt/nexus
# see https://www.sonatype.com/download-oss-sonatype
# see https://help.sonatype.com/repomanager3/product-information/download/download-archives---repository-manager-3
# see https://help.sonatype.com/repomanager3/product-information/release-notes
# see https://help.sonatype.com/repomanager3
nexus_version=3.75.1-01
nexus_home=/opt/nexus/nexus-$nexus_version
nexus_tarball=nexus-$nexus_version-unix.tar.gz
nexus_download_url=https://download.sonatype.com/nexus/3/$nexus_tarball
nexus_download_sha1=cfc9e7bdaeb1f1b9fb45aecc7a50821759c8b847
wget -q $nexus_download_url
if [ "$(sha1sum $nexus_tarball | awk '{print $1}')" != "$nexus_download_sha1" ]; then
    echo "downloaded $nexus_download_url failed the checksum verification"
    exit 1
fi
tar xf $nexus_tarball # NB this creates the $nexus_home (e.g. nexus-3.75.1-01) and sonatype-work directories.
rm $nexus_tarball
install -d -o nexus -g nexus -m 700 .java # java preferences are saved here (the default java.util.prefs.userRoot preference).
install -d -o nexus -g nexus -m 700 sonatype-work/nexus3/etc
chown -R nexus:nexus sonatype-work
grep -v -E '\s*##.*' $nexus_home/etc/nexus-default.properties >sonatype-work/nexus3/etc/nexus.properties
sed -i -E 's,(application-host=).+,\1127.0.0.1,g' sonatype-work/nexus3/etc/nexus.properties
sed -i -E 's,nexus-pro-,nexus-oss-,g' sonatype-work/nexus3/etc/nexus.properties
cat >>sonatype-work/nexus3/etc/nexus.properties <<'EOF'

# disable the wizard.
nexus.onboarding.enabled=false

# disable generating a random password for the admin user.
nexus.security.randompassword=false

# allow the use of groovy scripts because we use them to configure nexus.
# see https://issues.sonatype.org/browse/NEXUS-23205
# see Scripting Nexus Repository Manager 3 at https://support.sonatype.com/hc/en-us/articles/360045220393
nexus.scripts.allowCreation=true

# enable the database console.
# see https://support.sonatype.com/hc/en-us/articles/213467158-How-to-reset-a-forgotten-admin-password-in-Sonatype-Nexus-Repository-3#DatabaseConsoleforh2Database
nexus.h2.httpListenerEnabled=true
nexus.h2.httpListenerPort=8082
EOF
diff -u $nexus_home/etc/nexus-default.properties sonatype-work/nexus3/etc/nexus.properties || true
popd


# trust the LDAP server certificate for user authentication (when enabled).
# NB this assumes you are running the Active Directory from https://github.com/rgl/windows-domain-controller-vagrant.
if [ "$config_authentication" = 'ldap' ]; then
echo '192.168.56.2 dc.example.com' >>/etc/hosts
openssl x509 -inform der -in /vagrant/shared/ExampleEnterpriseRootCA.der -out /usr/local/share/ca-certificates/ExampleEnterpriseRootCA.crt
update-ca-certificates -v
fi


# start nexus.
cat >/etc/systemd/system/nexus.service <<EOF
[Unit]
Description=Nexus
After=network.target

[Service]
Type=simple
User=nexus
Group=nexus
ExecStart=$nexus_home/bin/nexus run
WorkingDirectory=$nexus_home
Restart=on-abort
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
systemctl enable nexus
systemctl start nexus

# install tools.
apt-get install -y --no-install-recommends httpie
apt-get install -y --no-install-recommends jq

# wait for nexus to come up.
bash -c "while [[ \"\$(wget -qO- https://$nexus_domain/service/extdirect/poll/rapture_State_get | jq -r .data.data.status.value.edition)\" != 'OSS' ]]; do sleep 5; done"

# print the version using the API.
wget -qO- https://$nexus_domain/service/extdirect/poll/rapture_State_get | jq --raw-output .data.data.uiSettings.value.title
wget -qO- https://$nexus_domain/service/extdirect/poll/rapture_State_get | jq .data.data.status.value


# generate a gpg key for the apt-hosted repository.
# see https://www.gnupg.org/documentation//manuals/gnupg/Unattended-GPG-key-generation.html
# see https://help.sonatype.com/repomanager3/formats/apt-repositories
# see https://wiki.archlinux.org/index.php/GnuPG#Unattended_passphrase
export GNUPGHOME="$(mktemp -d)"
cat >"$GNUPGHOME/apt-hosted-gpg-batch" <<EOF
%echo Generating apt-hosted key...
Key-Type: RSA
Key-Length: 4096
Key-Usage: sign
#Subkey-Type: RSA
#Subkey-Length: 4096
#Subkey-Usage: sign
Name-Real: apt-hosted
Name-Email: apt-hosted@$nexus_domain
Name-Comment: nexus apt-hosted
Expire-Date: 0
Passphrase: abracadabra
%commit
%echo done
EOF
cat >"$GNUPGHOME/gpg-agent.conf" <<EOF
allow-loopback-pinentry
EOF
gpgconf --kill gpg-agent
gpg --batch --generate-key "$GNUPGHOME/apt-hosted-gpg-batch"
gpg \
    --export \
    --armor \
    "apt-hosted@$nexus_domain" \
    >/vagrant/shared/apt-hosted-public.key
gpg \
    --export-secret-key \
    --armor \
    --pinentry-mode loopback \
    --passphrase abracadabra \
    "apt-hosted@$nexus_domain" \
    >/vagrant/shared/apt-hosted-private.key
gpgconf --kill gpg-agent
rm -rf "$GNUPGHOME"
unset GNUPGHOME


# configure nexus with the groovy script.
bash /vagrant/provision/execute-provision.groovy-script.sh

# set the api credentials.
api_auth="admin:admin"


# create the adhoc-package raw repository.
# NB this repository can host any type of artifact, so we disable strictContentTypeValidation.
# see https://help.sonatype.com/display/NXRM3/Raw+Repositories+and+Maven+Sites#RawRepositoriesandMavenSites-UploadingFilestoHostedRawRepositories
http \
    --check-status \
    --auth "$api_auth" \
    POST \
    https://$nexus_domain/service/rest/v1/repositories/raw/hosted \
    <<'EOF'
{
  "name": "adhoc-package",
  "online": true,
  "storage": {
    "blobStoreName": "default",
    "strictContentTypeValidation": false,
    "writePolicy": "allow_once"
  },
  "component": {
    "proprietaryComponents": true
  }
}
EOF


# create the apt-hosted apt repository.
# see https://help.sonatype.com/repomanager3/formats/apt-repositories
http \
    --check-status \
    --auth "$api_auth" \
    POST \
    https://$nexus_domain/service/rest/v1/repositories/apt/hosted \
    <<EOF
{
  "name": "apt-hosted",
  "online": true,
  "storage": {
    "blobStoreName": "default",
    "strictContentTypeValidation": true,
    "writePolicy": "allow_once"
  },
  "component": {
    "proprietaryComponents": true
  },
  "apt": {
    "distribution": "jammy"
  },
  "aptSigning": {
    "keypair": $(cat /vagrant/shared/apt-hosted-private.key | jq --slurp --raw-input .),
    "passphrase": "abracadabra"
  }
}
EOF


# create the npm-hosted npm repository.
# see https://help.sonatype.com/display/NXRM3/Node+Packaged+Modules+and+npm+Registries
http \
    --check-status \
    --auth "$api_auth" \
    POST \
    https://$nexus_domain/service/rest/v1/repositories/npm/hosted \
    <<'EOF'
{
  "name": "npm-hosted",
  "online": true,
  "storage": {
    "blobStoreName": "default",
    "strictContentTypeValidation": true,
    "writePolicy": "allow_once"
  },
  "component": {
    "proprietaryComponents": true
  }
}
EOF


# create the npmjs.org-proxy npm proxy repository.
# see https://help.sonatype.com/display/NXRM3/Node+Packaged+Modules+and+npm+Registries
http \
    --check-status \
    --auth "$api_auth" \
    POST \
    https://$nexus_domain/service/rest/v1/repositories/npm/proxy \
    <<'EOF'
{
  "name": "npmjs.org-proxy",
  "online": true,
  "storage": {
    "blobStoreName": "default",
    "strictContentTypeValidation": true,
    "writePolicy": "allow_once"
  },
  "proxy": {
    "remoteUrl": "https://registry.npmjs.org",
    "contentMaxAge": 1440,
    "metadataMaxAge": 1440
  },
  "negativeCache": {
    "enabled": true,
    "timeToLive": 1440
  },
  "httpClient": {
    "blocked": false,
    "autoBlock": true
  }
}
EOF


# create the npm-group npm group repository.
# see https://help.sonatype.com/display/NXRM3/Node+Packaged+Modules+and+npm+Registries
http \
    --check-status \
    --auth "$api_auth" \
    POST \
    https://$nexus_domain/service/rest/v1/repositories/npm/group \
    <<'EOF'
{
  "name": "npm-group",
  "online": true,
  "storage": {
    "blobStoreName": "default",
    "strictContentTypeValidation": true
  },
  "group": {
    "memberNames": [
      "npm-hosted",
      "npmjs.org-proxy"
    ]
  }
}
EOF


# create the pypi-hosted repository.
http \
    --check-status \
    --auth "$api_auth" \
    POST \
    https://$nexus_domain/service/rest/v1/repositories/pypi/hosted \
    <<'EOF'
{
  "name": "pypi-hosted",
  "online": true,
  "storage": {
    "blobStoreName": "default",
    "strictContentTypeValidation": true,
    "writePolicy": "allow_once"
  },
  "component": {
    "proprietaryComponents": true
  }
}
EOF


# create the powershell-hosted nuget hosted repository.
# see https://help.sonatype.com/en/nuget-repositories.html
http \
    --check-status \
    --auth "$api_auth" \
    POST \
    https://$nexus_domain/service/rest/v1/repositories/nuget/hosted \
    <<'EOF'
{
  "name": "powershell-hosted",
  "online": true,
  "storage": {
    "blobStoreName": "default",
    "strictContentTypeValidation": true,
    "writePolicy": "allow_once"
  },
  "component": {
    "proprietaryComponents": true
  }
}
EOF


# create a powershellgallery.com-proxy powershell proxy repository.
# see https://help.sonatype.com/en/nuget-repositories.html
http \
    --check-status \
    --auth "$api_auth" \
    POST \
    https://$nexus_domain/service/rest/v1/repositories/nuget/proxy \
    <<'EOF'
{
  "name": "powershellgallery.com-proxy",
  "online": true,
  "storage": {
    "blobStoreName": "default",
    "strictContentTypeValidation": true
  },
  "proxy": {
    "remoteUrl": "https://www.powershellgallery.com/api/v2/",
    "contentMaxAge": 1440,
    "metadataMaxAge": 1440
  },
  "nugetProxy": {
    "queryCacheItemMaxAge": 3600,
    "nugetVersion": "V2"
  },
  "negativeCache": {
    "enabled": true,
    "timeToLive": 1440
  },
  "httpClient": {
    "blocked": false,
    "autoBlock": true
  }
}
EOF


# create the powershell-group nuget group repository.
# see https://help.sonatype.com/en/nuget-repositories.html
http \
    --check-status \
    --auth "$api_auth" \
    POST \
    https://$nexus_domain/service/rest/v1/repositories/nuget/group \
    <<'EOF'
{
  "name": "powershell-group",
  "online": true,
  "storage": {
    "blobStoreName": "default",
    "strictContentTypeValidation": true
  },
  "group": {
    "memberNames": [
      "powershell-hosted",
      "powershellgallery.com-proxy"
    ]
  }
}
EOF


# create the chocolatey-hosted nuget hosted repository.
# see https://help.sonatype.com/en/nuget-repositories.html
http \
    --check-status \
    --auth "$api_auth" \
    POST \
    https://$nexus_domain/service/rest/v1/repositories/nuget/hosted \
    <<'EOF'
{
  "name": "chocolatey-hosted",
  "online": true,
  "storage": {
    "blobStoreName": "default",
    "strictContentTypeValidation": true,
    "writePolicy": "allow_once"
  },
  "component": {
    "proprietaryComponents": true
  }
}
EOF


# create a chocolatey.org-proxy nuget proxy repository.
# see https://help.sonatype.com/en/nuget-repositories.html
http \
    --check-status \
    --auth "$api_auth" \
    POST \
    https://$nexus_domain/service/rest/v1/repositories/nuget/proxy \
    <<'EOF'
{
  "name": "chocolatey.org-proxy",
  "online": true,
  "storage": {
    "blobStoreName": "default",
    "strictContentTypeValidation": true
  },
  "proxy": {
    "remoteUrl": "https://chocolatey.org/api/v2/",
    "contentMaxAge": 1440,
    "metadataMaxAge": 1440
  },
  "nugetProxy": {
    "queryCacheItemMaxAge": 3600,
    "nugetVersion": "V2"
  },
  "negativeCache": {
    "enabled": true,
    "timeToLive": 1440
  },
  "httpClient": {
    "blocked": false,
    "autoBlock": true
  }
}
EOF


# create the chocolatey-group nuget group repository.
# see https://help.sonatype.com/en/nuget-repositories.html
http \
    --check-status \
    --auth "$api_auth" \
    POST \
    https://$nexus_domain/service/rest/v1/repositories/nuget/group \
    <<'EOF'
{
  "name": "chocolatey-group",
  "online": true,
  "storage": {
    "blobStoreName": "default",
    "strictContentTypeValidation": true
  },
  "group": {
    "memberNames": [
      "chocolatey-hosted",
      "chocolatey.org-proxy"
    ]
  }
}
EOF


# configure nexus ldap with a groovy script.
if [ "$config_authentication" = 'ldap' ]; then
    bash /vagrant/provision/execute-provision-ldap.groovy-script.sh
fi
