#!/bin/bash

set -e

export POLYAXON_NO_OP=1
app_name=$CI_COMMIT_REF_NAME
#app_name=$(git branch | grep \* | cut -d ' ' -f2)

# Get next assignment
next_assignment=$(find . -maxdepth 1 -name "assignment*" | wc -l | tr -d '[:space:]')
current=$(($next_assignment - 1))
current_assignment="assignment$current"
echo "Current assignment: $current"
echo "Evaluating $current_assignment"

# Remove and copy folders accordingly
if [ $current -lt 7 ] && [ -d $MASTER/$current_assignment/tests ]
then
    # Remove apprentice's copy of tests folder
    rm -rf $current_assignment/tests
    # Copy master copy of tests into apprentice's folder
    cp -r $MASTER/$current_assignment/tests $current_assignment
elif [ $current -eq 7 ]
then
    # Remove apprentice's copy of skaffold, and ci
    rm -rf $current_assignment/ci $current_assignment/skaffold.yaml
    # Copy master copy of skaffold, and ci
    cp -r $MASTER/$current_assignment/ci $MASTER/$current_assignment/skaffold.yaml $current_assignment
fi

post_evaluation() {
    thread_url="$MENTOR_WEBHOOK_URL&threadKey=$current_assignment"

    curl -X POST \
        "$thread_url" \
        -H "Content-Type: application/json; charset=UTF-8" \
        -d '{ "text": "'"$post_text"'",
        }' \
        -s > /dev/null
}

download_test_data() {
    if [ "$1" -eq "3" ]
    then
        curl -o /data/A"$1"_train.csv "https://aiapstorage1.blob.core.windows.net/datasets/assignment$1_train.csv"
        curl -o /data/A"$1"_test.csv "https://aiapstorage1.blob.core.windows.net/datasets/assignment$1_test.csv"
    elif [ "$1" -gt "0" -a "$1" -lt "5" ]
    then
        curl -o /data/A$1.csv "https://aiapstorage1.blob.core.windows.net/datasets/assignment$1_test.csv"
    fi
}

if [ -d "$current_assignment/tests" ]
then
    # Update conda environment
    if [ ! -f "$current_assignment/conda.yml" ]
    then
        echo "No conda file found for $current_assignment"
        exit 1
    fi
    conda env update -n base --file "$current_assignment/conda.yml"

    # download test data for current assignment
    download_test_data "$current"

    # Perform pytest
    pip install pytest pylint radon    # Manually put these back since conda env update removes them
    pytest -x -v -s "$current_assignment/tests"
    test_exit_code=$?
    if [ "$current" -eq "7" -a "$test_exit_code" -eq "5" ]
    then
        echo "No tests were written 😩"
        exit 1
    elif [ "$test_exit_code" -gt "0" ]
    then
        echo "Test failed"
        exit 1
    fi

    # Perform lint scoring
    pylint "$current_assignment"/src || true # continue with pipeline even if there are pylint errors
    lint_score=$(pylint "$current_assignment"/src | grep "Your code has been rated at" | grep -Eo "[-]{0,1}[0-9]+[.][0-9]+" | head -1)
    int_score=${lint_score%.*}

    # Perform cc test
    echo "Cyclomatic complexity"
    radon cc -e '**/__init__.py' "$current_assignment/src" || true

    # Perform mi test
    echo -e "\nMaintainability index"
    radon mi -e '**/__init__.py' "$current_assignment/src" || true
    #radon raw -e '**/__init__.py' "$current_assignment"/src
    #radon hal -e '**/__init__.py' "$current_assignment"/src
    echo ""

    # Fail pipeline if lint score is less than 7
    if [ "$int_score" -gt "7" ]
    then
        echo "Eval passed. Posting result to chat channel:"
        post_text="'"${app_name}"' test passed. Lint score: '"${int_score}"'"
        post_evaluation
        echo $post_text
    else
        echo "Lint score failed: $int_score"
        exit 1
    fi

else
    echo "$current_assignment has no tests. Skipping eval and posting to chat channel."
    post_text="$current_assignment has no tests. Skipping eval for $app_name"
    post_evaluation
fi
