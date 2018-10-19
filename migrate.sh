#!/bin/bash
set -x

ABSDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
DIR="$(basename $ABSDIR)"

# data source
SOURCE="${1:-from}"
SOURCEC="${DIR}_${SOURCE}_1"

# destination
TABLET_ID=${2:-1}
DATA_DIR="/vt/vtdataroot/vt_000000000${TABLET_ID}"
TARGET=vttablet${TABLET_ID}
TARGETC="${DIR}_${TARGET}_1"


# vitess uses a vt_ prefix
echo "CREATE DATABASE vt_test_keyspace; USE vt_test_keyspace; CREATE TABLE messages (
  page BIGINT(20) UNSIGNED,
  time_created_ns BIGINT(20) UNSIGNED,
  message VARCHAR(10000),
  PRIMARY KEY (page, time_created_ns)
  ) ENGINE=InnoDB; INSERT INTO messages VALUES (1, NOW(), 'baz');" | mysql -uroot -proot --port 4000 --host 127.0.0.1

# os-deps
docker-compose exec ${SOURCE} bash -c "apt update -y; apt install pv vim percona-toolkit wget socat netcat lsb-release -y; wget https://repo.percona.com/apt/percona-release_0.1-6.stretch_all.deb; dpkg -i percona-release_0.1-6.stretch_all.deb; apt-get update -y; apt-get install percona-xtrabackup-24 -y"
docker-compose exec -u root $TARGET bash -c "apt update -y; apt install pv vim percona-toolkit wget socat netcat lsb-release -y; wget https://repo.percona.com/apt/percona-release_0.1-6.stretch_all.deb; dpkg -i percona-release_0.1-6.stretch_all.deb; apt-get update -y; apt-get install percona-xtrabackup-24 -y"

# create backup & move it to vttablet (this will be done over network)
docker-compose exec ${SOURCE} bash -c 'innobackupex --password=root --stream=xbstream --ftwrl-wait-threshold=40 --ftwrl-wait-query-type=all --ftwrl-wait-timeout=180 --kill-long-queries-timeout=20 --kill-long-query-type=all /var/lib/mysql > /backup'
docker cp ${SOURCEC}:/backup .
docker cp ./backup ${TARGETC}:/backup

# kill mysqld; restore backup
docker-compose exec -u root $TARGET bash -c "
  # shutdown running mysqld
  /vt/bin/mysqlctl -log_dir /vt/vtdataroot/tmp -tablet_uid $TABLET_ID -mysql_port 3306 shutdown

  # delete data dir
  rm -rf $DATA_DIR;
  mkdir $DATA_DIR;

  # restore data dir from backup
  cd ${DATA_DIR};
  cat /backup | xbstream -x -C $DATA_DIR;
  innobackupex --apply-log $DATA_DIR;
  ls -la

  # create create mysql config file (vitess uses custom dirs for innodb data and binlogs)
  /vt/bin/mysqlctl -log_dir /vt/vtdataroot/tmp -tablet_uid $TABLET_ID -mysql_port 3306 init_config;

  # move system tables to mysql-data dir
  mv mysql performance_schema sys data

  # move innodb data
  mv ib_buffer_pool innodb/data/
  mv ibdata1  innodb/data/
  mv ib_logfile0 innodb/logs/
  mv ib_logfile1 innodb/logs/

  # overwrite tablespace with our data
  rm -rf data/vt_test_keyspace/
  cp -r vt_test_keyspace data/
  chown -R vitess: $DATA_DIR"

docker-compose restart $TARGET

sleep 10


docker-compose exec -u root $TARGET bash -c "cat /vt/init_db.sql | mysql -uroot -proot -h 127.0.0.1"
docker-compose exec -u root $TARGET bash -c "echo \"GRANT ALL ON *.* TO 'root'@'%' identified by '';\" | mysql -uroot -proot -h 127.0.0.1"


