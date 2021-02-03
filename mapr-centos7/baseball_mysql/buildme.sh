#!/bin/bash

time docker build -t $(basename $(pwd)):10.5 .
