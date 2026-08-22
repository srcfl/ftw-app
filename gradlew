#!/bin/sh

##############################################################################
# Gradle start up script for UN*X
##############################################################################

app_path=$0
APP_HOME=$(cd "${app_path%/*}" && pwd)
APP_BASE_NAME=${0##*/}

DEFAULT_JVM_OPTS="-Xmx64m -Xms64m"

if [ -n "$JAVA_HOME" ] ; then
    JAVACMD="$JAVA_HOME/bin/java"
else
    JAVACMD="java"
fi

CLASSPATH=$APP_HOME/gradle/wrapper/gradle-wrapper.jar

exec "$JAVACMD" $DEFAULT_JVM_OPTS $JAVA_OPTS $GRADLE_OPTS \
    -classpath "$CLASSPATH" org.gradle.wrapper.GradleWrapperMain "$@"
