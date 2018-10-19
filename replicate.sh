#!/bin/bash
set -x

TABLET_ID=${1}
DATA_DIR="/vt/vtdataroot/vt_000000000${TABLET_ID}"
TARGET="vttablet${TABLET_ID}"
REPL_TARGET=${2}
REPL_USER=${3}
REPL_PASS=${4}

docker-compose exec $TARGET bash -c "
  BINLOGPOS_1=\$(cat ${DATA_DIR}/xtrabackup_binlog_info | awk ' { print \$3 } ')
  BINLOGPOS_2=\$(cat ${DATA_DIR}/xtrabackup_binlog_info | tail -n +2 | tr -d '\n')
  BINLOGPOS="\${BINLOGPOS_1}\${BINLOGPOS_2}"
  echo found binlog position: \$BINLOGPOS

  mysql -uroot -h 127.0.0.1 <<SQL
    STOP SLAVE;
    RESET SLAVE;
    RESET MASTER;
    SET GLOBAL gtid_purged=\"\$BINLOGPOS\";
    CHANGE MASTER TO
      MASTER_HOST='$REPL_TARGET',
      MASTER_PORT=3306,
      MASTER_USER='$REPL_USER',
      MASTER_PASSWORD='$REPL_PASS',
      MASTER_AUTO_POSITION=1;
    START SLAVE;
SQL
"

sleep 1;

docker-compose exec $TARGET mysql -uroot -h 127.0.0.1 -e "SHOW SLAVE STATUS \G"
