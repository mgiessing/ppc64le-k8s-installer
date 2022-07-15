#!/bin/bash

if ! command -v ansible &> /dev/null
then
    echo "ansible could not be found"
    exit
fi
