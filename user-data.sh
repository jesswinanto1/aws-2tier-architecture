#!/bin/bash
apt update -y
apt install -y apache2
systemctl start apache2
systemctl enable apache2
echo "<h1>Hello from $(hostname -f)</h1>" > /var/www/html/index.html
