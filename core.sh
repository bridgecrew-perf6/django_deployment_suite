#!/bin/bash
source init.conf
git_url=$1

# Get project name from git URL
IFS='/'
read -ra project_name <<< "$git_url"
project_name=${project_name[-1]%".git"}
IFS=''

main_dir=$HOME'/'$project_name'_main'
# echo 'main_dir = '$main_dir
project_dir=$main_dir/$project_name

sudo apt update -y
sudo apt install git python3-pip python3-dev libpq-dev nginx curl ufw virtualenv -y
sudo -H pip3 install --upgrade pip
sudo -H pip3 install virtualenv

cd ~
mkdir $main_dir
cd $main_dir
git clone $git_url
mkdir $project_dir/static/temp $project_dir/logs
sudo chmod -R 775 $project_dir


##Getting module name

module_path=$(find $project_dir -name wsgi.py)
IFS='/'
read -ra module_name <<< "$module_path"
module_name=${module_name[-2]}
IFS=''

virtualenv --python=python3 $env_name
source $env_name/bin/activate

pip install django gunicorn psycopg2-binary
pip install -r $project_dir/requirements.txt
#sudo chown -R $linux_admin_user: $main_dir/$env_name
nltk_data_dir=$main_dir/$env_name/share/nltk_data
python -c "import nltk; nltk.download('stopwords', download_dir='"$nltk_data_dir"'); nltk.download('wordnet', download_dir='"$nltk_data_dir"');"

sed -i 's/DEBUG = .*/DEBUG = False/g' $project_dir/$module_name/settings.py
sed -i 's/ALLOWED_HOSTS = .*/ALLOWED_HOSTS = ["'$domain_name'","'$ip_address'","localhost"]/g' $project_dir/$module_name/settings.py
sed -i 's:STATIC_URL = .*:STATIC_URL = "'$staticURL'":g' $project_dir/$module_name/settings.py
sed -i 's:STATIC_ROOT = .*:STATIC_ROOT = os.path.join(BASE_DIR, "'$staticRoot'"):g' $project_dir/$module_name/settings.py


## Enabling logging

if ! grep -q "LOGGING =" $project_dir/$module_name/settings.py ; then
	cat >> $project_dir/$module_name/settings.py << EOF

LOGGING = {
    'version': 1,
    'disable_existing_loggers': False,
    'handlers': {
        'file': {
            'level': 'DEBUG',
            'class': 'logging.FileHandler',
            'filename': os.path.join(BASE_DIR, 'logs/debug.log'),
        },
    },
    'loggers': {
        'django': {
            'handlers': ['file'],
            'level': 'DEBUG',
            'propagate': True,
        },
    },
}
EOF
fi

yes yes | $project_dir/manage.py makemigrations
yes yes | $project_dir/manage.py migrate
yes yes | $project_dir/manage.py collectstatic
# $project_dir/manage.py createsuperuser

deactivate

echo ''
echo '----------- CREATING "GUNICORN" SOCKET-------------'
echo ''

sudo su -l $linux_root_user -c "cat > /etc/systemd/system/gunicorn.socket << EOF
[Unit]
Description=gunicorn socket

[Socket]
ListenStream=/run/gunicorn.sock

[Install]
WantedBy=sockets.target
 
EOF
"

echo ''
echo '----------- CREATING "GUNICORN" SERVICE-------------'
echo ''

sudo su -l $linux_root_user -c "cat > /etc/systemd/system/gunicorn.service << EOF
[Unit]
Description=gunicorn daemon
Requires=gunicorn.socket
After=network.target

[Service]
User=$(whoami)
Group=www-data
WorkingDirectory=$project_dir
ExecStart=$main_dir/$env_name/bin/gunicorn \
          --access-logfile - \
          --workers 3 \
          --bind unix:/run/gunicorn.sock \
          $module_name.wsgi:application

[Install]
WantedBy=multi-user.target
 
EOF
"

sudo systemctl enable gunicorn.service
sudo systemctl enable gunicorn.socket
sudo systemctl start gunicorn.socket
sudo systemctl start gunicorn.service

if [ ! -e /run/gunicorn.sock ]; then
	echo "ERROR - /run/gunicorn.sock file not found"
	sudo journalctl -u gunicorn.socket
	exit 0
fi

echo ''
echo '----------- TESTING SOCKET ACTIVATION -------------'
echo ''
curl --unix-socket /run/gunicorn.sock localhost

sleep 3

if [[ -z $(sudo systemctl status gunicorn | grep 'Active: active') ]]; then
	echo "gunicorn is NOT running"
	exit 0
fi

sudo su -l $linux_root_user -c "cat > /etc/nginx/sites-available/$project_name << EOF
server {
    listen 80;
    server_name $ip_address;

    location = /favicon.ico { access_log off; log_not_found off; }
    location $staticURL {
        root $project_dir;
    }

    location / {
        include proxy_params;
        proxy_pass http://unix:/run/gunicorn.sock;
    }
}

EOF
"

sudo ln -s /etc/nginx/sites-available/$project_name /etc/nginx/sites-enabled

sudo systemctl restart nginx
sudo service ufw start
sudo ufw default deny
sudo ufw allow 22
sudo ufw allow 'Nginx Full'
yes | sudo ufw enable