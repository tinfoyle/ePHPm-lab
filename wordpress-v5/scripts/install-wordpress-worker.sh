#!/bin/sh
set -eu

cd /app
if [ -x vendor/bin/ephpm-wp-worker ]; then
  exit 0
fi

git config --global --add url.https://github.com/.insteadOf git@github.com:
git config --global --add url.https://github.com/.insteadOf ssh://git@github.com/
composer config --global github-protocols https
composer init --name=ephpm-lab/wordpress-v5 --no-interaction
composer config repositories.wordpress-worker vcs https://github.com/ephpm/wordpress-worker
composer config repositories.php-worker vcs https://github.com/ephpm/php-worker
composer require --no-interaction --prefer-dist ephpm/wordpress-worker:0.1.2
