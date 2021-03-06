#!/bin/bash
#?Usage:
#? tj.sh [-h] [clean] [<tests_path>] <main_java_program>
#?    [-t | -T <n> | -f <s> | -n &ltI> ] 
#? actions:
#?    clean               Delete diff and res files
#? -h, --help             Help on command usage
#? -t, --timed            Display time taken to execute the code
#? -T <n>, --timeout <n>  Larges amount of seconds allowed before
#?                        timeout
#?                        Default: 1
#? -n <I>                 Interval range of tests
#?                        using ~ instead of - selects complement
#?                        a-b   (a, b]
#?                        a-    (a, ...)
#?                         -b   (..., b]
#?                         ~b   (b, ...)
#?                        a~b   (..., a]U(b, ...)
#?                        Default: '-' (all)
#? -f <s>, --format <s>   Format of test data prefix
#?                        Default: 'test'
#? -a <I>, --argc <I>     Number of command-line arguments
#?                        0 - in/out testing format: <exe> < <in-file> > <res-file>
#?                        1 - in/out testing format: <exe> <in-file> > <res-file>
#?                        2 - in/out testing format: <exe> <in-file> <res-file>
#?                        Default: 0"

TJ_PATH="."
TESTS=""
ARGC=0
ENTRY_FUNCTION="main"
FILE_PREFIX="test"
TIMEOUT_VAL=1 #in seconds
KILL_AFTER=$((TIMEOUT_VAL+2))
TIMED=0

JC="javac"
JCFLAGS=""

DIFF_TIMEOUT=1
LOG="/dev/null"

TIMEOUT_SIGNAL=124
SHELL="/bin/bash"
OK_STRING="\033[1;32mOK\033[0;38m"
FAILED_STRING="\033[1;31mfailed\033[0;38m"
TIMEOUT_STRING="\033[1;35mtimeout\033[0;38m"

### CHECKING IF ALL THE PROGRAMS EXIST
REQUIRED_PROGRAMS=("awk" "basename" "bc" "cut" "date" "diff" "find" "grep" "realpath" "sort" "timeout" "javac")

for PROGRAM in ${REQUIRED_PROGRAMS[@]}; do
    if ! command -v $PROGRAM &> /dev/null; then
        echo "Error: '$PROGRAM' not found, exiting" >&2
        exit 1
    fi
done

function print_help
{
    echo " tj.sh [-h] [clean] [<tests_path>] <main_java_program>"
    echo "    [-t | -T <n> | -f <s> | -n &ltI> ] "
    echo
    echo " actions:"
    echo "    clean               Delete diff and res files"
    echo
    echo " -h, --help             Help on command usage"
    echo " -t, --timed            Display time taken to execute the code"
    echo " -T <n>, --timeout <n>  Larges amount of seconds allowed before"
    echo "                        timeout"
    echo "                        Default: 1"
    echo " -n <I>                 Interval range of tests"
    echo "                        using ~ instead of - selects complement"
    echo "                        a-b   (a, b]"
    echo "                        a-    (a, ...)"
    echo "                         -b   (..., b]"
    echo "                         ~b   (b, ...)"
    echo "                        a~b   (..., a]U(b, ...)"
    echo "                        Default: '-' (all)"
    echo " -f <s>, --format <s>   Format of test data prefix"
    echo "                        Default: 'test'"
    echo " -a <I>, --argc <I>     Number of command-line arguments"
    echo "                        0 - in/out testing format: <exe> < <in-file> > <res-file>"
    echo "                        1 - in/out testing format: <exe> <in-file> > <res-file>"
    echo "                        2 - in/out testing format: <exe> <in-file> <res-file>"
    echo "                        Default: 0"
}


### ARGUMENT PARSING
POS_PARAMS=""

while (( "$#" )); do
  case "$1" in
    -h|--help)
      print_help
      exit 0
      ;;
    -t|--timed)
      TIMED=1
      shift
      ;;
    -T|--timeout)
      if [ -n "$2" ] && [ ${2:0:1} != "-" ]; then
        TIMEOUT_VAL=$2
        shift 2
      else
        echo "Error: Missing value for $1" >&2
        print_help
        exit 1
      fi
      ;;
    -a|--argc)
      if [ -n "$2" ]; then
        if [[ $2 =~ ^[0-2]$ ]]; then
            ARGC=$2
            shift 2
        else
            echo "Error: Invalid value for $1" >&2
            print_help
            exit 1
        fi
      fi
      ;;
    -f|--format)
      if [ -n "$2" ] && [ ${2:0:1} != "-" ]; then
        FILE_PREFIX=$2
        shift 2
      else
        echo "Error: Missing value for $1" >&2
        print_help
        exit 1
      fi
      ;;
    -n)
        if [ -n "$2" ]; then
            if [[ $2 =~ ^([1-9][0-9]*)?(\-|\~)([1-9][0-9]*)?$ ]]; then
                if [[ ${#2} -le 1 ]]; then # CASE '-n -'' or '-n ~' 
                    TESTS=""
                else
                    TESTS=$2
                fi
                shift 2
            else
                echo "Error: Invalid value for $1" >&2
                print_help
                exit 1
            fi
        else
            echo "Error: Missing value for $1" >&2
            print_help
            exit 1
        fi
    ;;
    -*|--*=) # unsupported flags
      echo "Error: Unexpected argument $1" >&2
      print_help
      exit 1
      ;;
    *) # preserve positional arguments
      POS_PARAMS="$POS_PARAMS $1"
      shift
      ;;
  esac
done
# set positional arguments in their proper place
eval set -- "$POS_PARAMS"

# Check for action/-s
ACTION="$1"
case "${ACTION^^}" in
    CLEAN)  #
        shift # consume action arg
        if [ $# -gt 1 ]; then
            echo "Invalid number of arguments" >&2
            print_help
            exit 1
        elif [ $# -eq 1 ]; then
            TJ_PATH="$1" # CASE tj clean <path>
        else
            TJ_PATH="."  # CASE tj clean
        fi
    ;;
    *) #default is to test
        if [ $# -gt 1 ]; then
            TJ_PATH="$1" # CASE tj [<path>] <main> [<additional> ...]
            shift
        fi
        # main_file
        MAIN_FILE="$1"
        shift
     ;;
esac


### VALIDATE

## Validate path

if [ ! -d "$TJ_PATH" ]; then
    echo "Error: '$TJ_PATH' is not a directory" >&2
    print_help
    exit 1
fi
# absolute path for safety
TJ_PATH=$(realpath "$TJ_PATH")


### HELPER FUNCTIONS

function remove_leading_dotslash { echo "$@" | sed -e "s/^\.\///g"; }
function get_test_num {
    echo "$@" | grep -Po "(?<=$FILE_PREFIX)([0-9]+)";
    }
function rm_extension { echo "$@" | grep -Po "(.*)(?=\.)"; }
function get_base_name { rm_extension $(basename "$1"); }
function get_exe {
    r=$(rm_extension $1)
    echo "java -cp $TJ_PATH $r";
}

### CLEANING


if [[ ${ACTION^^} = "CLEAN" ]]; then
    file_matches=$(find $TJ_PATH -maxdepth 1 -type f | grep -E $FILE_PREFIX[0-9]+\.\(res\|diff\)\|$MAIN_FILE*.class | sort) # Search for tests
    
    if [ $(echo "$file_matches" | wc -w) = "0" ]; then
        echo "Nothing to remove"
        exit 0
    fi
    echo "$file_matches"
    echo "Remove all [y/n]?"
    read -p "> " ans
    if [ ${ans^^}  = "Y" ]; then
        #rm "$file_matches"
        for f in "$file_matches"; do
            rm $(remove_leading_dotslash "$f")
        done
    fi
    exit 0
fi


### COMPILING FUNCTION

function compile {
    abs_target=$(realpath "$1")
    base_name=$(rm_extension $abs_target)
    base_target=$(basename "$1")
    $JC $JCFLAGS -d $TJ_PATH $abs_target
    exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        echo -e "Compiling file $base_target $FAILED_STRING, exiting" >&2
        exit 1
    fi
    echo "Compiled $base_target"
}


### DETECTING TYPE OF TESTING

test_in_files=$(find $TJ_PATH -maxdepth 1 -type f | grep -E $FILE_PREFIX[0-9]+\.in  | sort ) # Search for tests
test_in_n=$(echo "$test_in_files" | wc -w | bc)

if [ $test_in_n -eq 0 ]; then
    echo "No tests found in $TJ_PATH." >&2
    exit 1
else
    echo "Using $test_in_n $FILE_PREFIX.in files."
    if [ -z "$MAIN_FILE" ]; then
        echo "Error: Missing main java file!" >&2
        exit 1
    fi
fi

test_cases="$test_in_files"


### FILTER TEST CASES

if [ ! -z "$TESTS" ]; then
    CUT_FLAGS=""
    if [[ $TESTS == *"~"* ]];then
        CUT_FLAGS="$CUT_FLAGS --complement"
        TESTS=${TESTS/"~"/"-"} # Replace complement
    fi
    # echo "$CUT_FLAGS $TESTS"
    test_cases=$(echo "$test_cases" | cut -d$'\n' -f$TESTS $CUT_FLAGS)
    unset CUT_FLAGS
fi
# echo "$test_cases"



echo " == COMPILING =="
compile "$MAIN_FILE"
exe_name=$(get_exe $MAIN_FILE)

all_tests=0
ok_tests=0
echo
echo " == TESTING =="
for test_case in $test_cases
do
    # Get variables for this case
    base_name=$(rm_extension "$test_case")
    file_name=$(basename $base_name)
    #i=$(get_test_num $file_name)
    #echo "$i $file_name"
    #echo "$base_name $test_case $file_name"
    java_base_name=$(realpath "$base_name")
    out_file="$base_name.out"

    # Check if .out exists
    if ! [ -f  "$out_file" ]; then
        echo "Missing $out_file for $test_case"
        continue
    else
        ### TESTING .in, .out
        in_file="$java_base_name.in"
        if ! [ -f  "$in_file" ]; then
            echo "Missing $in_file for $test_case"
            continue
        fi
        start_time=$(date +%s.%N)
        if [[ "$ARGC" == "0" ]]; then
	        $(timeout -k $KILL_AFTER $TIMEOUT_VAL $exe_name < $in_file > $java_base_name.res 2>&1) 2> /dev/null
        elif [[ "$ARGC" == "1" ]]; then
	        $(timeout -k $KILL_AFTER $TIMEOUT_VAL $exe_name $in_file > $java_base_name.res 2>&1) 2> /dev/null
        else
	        $(timeout -k $KILL_AFTER $TIMEOUT_VAL $exe_name $in_file $java_base_name.res 2>&1) 2> /dev/null
        fi
        exit_code=$?
        end_time=$(date +%s.%N)
        if [[ $exit_code == $TIMEOUT_SIGNAL ]]; then
            echo -e "${file_name^} -- $TIMEOUT_STRING [> $TIMEOUT_VAL s]"
        else
            if [ $TIMED -eq 1 ]; then
                timeDifference=" [$(echo "scale=2; $end_time - $start_time" | bc | awk '{printf "%.2f\n", $0}') s]"
            else
                timedDifference=""
            fi
            timeout -k $DIFF_TIMEOUT $DIFF_TIMEOUT diff --ignore-trailing-space $base_name.out $base_name.res > $base_name.diff
            exit_code=$?
            if [[ $exit_code == $TIMEOUT_SIGNAL ]]; then
                echo -e "${file_name^} -- $FAILED_STRING (diff errored)$timeDifference"
            elif [ -s "$base_name.diff" ]; then
                echo -e "${file_name^} -- $FAILED_STRING$timeDifference"
            else
                echo -e "${file_name^} -- $OK_STRING$timeDifference"
                ((ok_tests+=1))
            fi
        fi
        ((all_tests+=1))
    fi
done

echo "Result: $ok_tests / $all_tests"
