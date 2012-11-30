#!/bin/bash

# Find path to this script
if [[ $0 == /* ]] ; then
    DIR=$(dirname "$0")
else
    DIR=$(dirname "${PWD}/${0#./}")
fi
source "$DIR/conf.sh" || exit 1

# Set default values
: ${SPINDLE_DIR:="$DIR/demo"}
: ${RABBITMQ_USER:=rabbitmq}
: ${PGUSER:=postgres}
: ${APACHECTL:=apachectl}

# Run as "run_spindle.sh conf" to print out configuration
if [[ "$1" == conf ]] ; then
    echo "LOG_DIR=$LOG_DIR"
    echo "VIRTUALENV=$VIRTUALENV"
    echo "SPINDLE_DIR=$SPINDLE_DIR"
    echo "PGLOG=$PGLOG"
    echo "PGDATA=$PGDATA"
    echo "PGUSER=$PGUSER"
    echo "APACHECTL=$APACHECTL"
    echo "RABBITMQ_USER=$RABBITMQ_USER"
    echo "CELERY_USER=$CELERY_USER"
    exit 0
fi

# Sanity check
if [[ -z "$LOG_DIR" || -z "$VIRTUALENV" || -z "$SPINDLE_DIR" || -z "$PGLOG" \
    || -z "$APACHECTL" || -z "$PGDATA" || -z "$PGUSER" || -z "$RABBITMQ_USER" \
    || -z "$CELERY_USER" ]] ; then
    echo 'Some variables not set. Check conf.sh'.
    exit 1
fi

# Find celery logfiles and PID file
CELERY_SPHINX_LOG="$LOG_DIR/celery.sphinx.log"
CELERY_LOCAL_LOG="$LOG_DIR/celery.local.log"
CELERYCAM_LOG="$LOG_DIR/celerycam.log"
CELERY_SPHINX_PIDFILE="$LOG_DIR/celery.sphinx.pid"
CELERY_LOCAL_PIDFILE="$LOG_DIR/celery.local.pid"
CELERYCAM_PIDFILE="$LOG_DIR/celerycam.pid"

# Run in the right virtual environment
source "$VIRTUALENV/bin/activate" || exit 1

postgres() {
    case "$1" in
        start)
            echo '* Starting postgres:'
            sudo -u "$PGUSER" pg_ctl -l $PGLOG -D $PGDATA start
            ;;

        stop)
            echo '* Stopping postgres:'
            sudo -u "$PGUSER" pg_ctl -D $PGDATA stop
            ;;

        stopfast)
            echo '* Stopping postgres fast:'
            sudo -u "$PGUSER" pg_ctl -l $PGLOG -D $PGDATA -m fast stop
            ;;

        *)
            echo '* Bad command "'$1'". Specify one of "start", "stop", "stopfast"'
            ;;
    esac
}

apache() {
    case "$1" in
        start)
            echo '* Starting apache:'
            "$APACHECTL" restart
            ;;

        stop)
            echo '* Stopping apache:'
            "$APACHECTL" stop
            ;;

        *) echo '* Bad command "'$1'". Specify one of "start", "stop".'
            ;;
    esac
}


celery() {
    case "$1" in
        start)
            echo '* Starting sphinx celery worker:'
            sudo -u "$CELERY_USER" \
                nohup "$SPINDLE_DIR/manage.py" celery worker \
                --settings=celery_sphinx_settings --autoreload -Q sphinx -E \
                --pidfile="$CELERY_SPHINX_PIDFILE" \
                --hostname="sphinx.$(hostname)" \
                --loglevel=info </dev/null >"$CELERY_SPHINX_LOG" 2>&1 &

            echo '* Starting local celery worker:'
            sudo -u "$CELERY_USER" \
                nohup "$SPINDLE_DIR/manage.py" celery worker \
                --settings=celery_local_settings --autoreload -Q local,celery -E \
                --pidfile="$CELERY_LOCAL_PIDFILE" \
                --hostname="local.$(hostname)" \
                --loglevel=info </dev/null >"$CELERY_LOCAL_LOG" 2>&1 &
            cat "$CELERY_LOCAL_PIDFILE"

            echo '* Starting celerycam monitor:'
            sudo -u "$CELERY_USER" \
                nohup "$SPINDLE_DIR/manage.py" celerycam \
                --pidfile="$CELERYCAM_PIDFILE" \
                </dev/null >"$CELERYCAM_LOG" 2>&1 &
            ;;

        stop)
            for pidfile in "$CELERY_SPHINX_PIDFILE" \
                "$CELERY_LOCAL_PIDFILE" "$CELERYCAM_PIDFILE" ; do

                if [ -f "$pidfile" ] ; then
                    pid=$(cat "$pidfile")
                    printf "* Stopping $pidfile [$pid]..."

                    kill -15 $pid
                    while kill -0 $pid ; do printf '.' ; sleep 1 ; done
                    echo

                    rm "$pidfile"
                fi
            done
            celery list
            ;;

        restart)
            celery stop
            celery start
            ;;

        list)
            ps ax | grep celery
            ;;

        log)
            tail -f "$CELERY_LOCAL_LOG" "$CELERY_SPHINX_LOG"
    esac
}

rabbitmq() {
    case "$1" in
        start)
            echo '* Starting rabbitmq'
            sudo -H -u "$RABBITMQ_USER" rabbitmq-server -detached
            ;;

        stop)
            echo '* Stopping rabbitmq'
            sudo -H -u "$RABBITMQ_USER" rabbitmqctl stop
            ;;
    esac
}



main() {
    case "$1" in
        start)
            postgres start
            rabbitmq start
            celery start
            if [ "$2" = dev ] ; then
                "$SPINDLE_DIR/manage.py" runserver
            else
                apache start
            fi
            ;;

        stop)
            celery stop
            apache stop
            rabbitmq stop
            postgres stop
            ;;

        postgres)
            shift
            postgres "$@"
            ;;

        apache)
            shift
            apache "$@"
            ;;

        celery)
            shift
            celery "$@"
            ;;

        rabbitmq)
            shift
            rabbitmq "$@"
            ;;

        *)
            echo 'Bad command: "'$1'".

Usage:
   run_spindle.sh conf | start | stop
                  | postgres ( start | stop | stopfast)
                  | apache ( start | stop )
                  | celery ( start | stop | restart )'
            exit 1
            ;;
    esac
}


main "$@"
