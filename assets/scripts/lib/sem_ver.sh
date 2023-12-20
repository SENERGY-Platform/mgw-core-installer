#!/bin/sh

extractDigits() {
  trimmedVer=${1#v}
  n1=${trimmedVer%%.*}
  printf "%s " $n1
  trimmedVer=${trimmedVer#$n1.}
  n2=${trimmedVer%%.*}
  printf "%s " $n2
  trimmedVer=${trimmedVer#$n2.}
  n3=${trimmedVer%%-*}
  printf "%s " $n3
  trimmedVer=${trimmedVer#$n3}
  n4=${trimmedVer#-beta}
  if [ "$n4" = "" ]
  then
    printf "%s" 0
  else
    printf "%s" $n4
  fi
}

digitsLessThan() {
  if [ $1 -lt $5 ]
  then
    return 0
  fi
  if [ $1 -eq $5 ]
  then
    if [ $2 -lt $6 ]
    then
      return 0
    fi
    if [ $2 -eq $6 ]
    then
      if [ $3 -lt $7 ]
      then
        return 0
      fi
      if [ $3 -eq $7 ]
      then
        if ! [ $4 -eq 0 ] && [ $4 -lt $8 ]
        then
          return 0
        fi
        if ! [ $4 -eq $8 ] && [ $8 -eq 0 ]
        then
          return 0
        fi
      fi
    fi
  fi
  return 1
}

semVerLessThan() {
  a=$(extractDigits "$1")
  b=$(extractDigits "$2")
  if digitsLessThan ${a} ${b}
  then
    return 0
  else
    return 1
  fi
}