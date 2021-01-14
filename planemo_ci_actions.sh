#!/usr/bin/env bash
set -ex

if [ "$CREATE_CACHE" != "false" ]; then
  tmp_dir=$(mktemp -d)
  touch "$tmp_dir/tool.xml"
  PIP_QUIET=1 planemo test --galaxy_python_version "$PYTHON_VERSION" --no_conda_auto_init --galaxy_source "$GALAXY_SOURCE" --galaxy_branch "$GALAXY_BRANCH" "$tmp_dir"
fi

if [ "$REPOSITORIES" == "" ]; then
  # The range of commits to check for changes is:
  # - `origin/master...` for all events happening on a feature branch
  # - for events on the master branch we compare against the sha before the event
  #   (note that this does not work for feature branch events since we want all
  #   commits on the feature branch and not just the commits of the last event)
  # - for pull requests we compare against the 1st ancestor, given the current
  #   HEAD is the merge between the PR branch and the base branch

  if [ "$GITHUB_EVENT_NAME" =  "push" ]; then
    case "$GITHUB_REF" in
      refs/heads/master|refs/heads/main )
      COMMIT_RANGE="36de8aa1927d0204107371ffad76bdfe921be44a.."
      # TODO RESTORE COMMIT_RANGE="$EVENT_BEFORE.."
      ;;
      *)
      git fetch origin master
      COMMIT_RANGE="origin/master..."
      ;;
    esac
  elif [ "$GITHUB_EVENT_NAME" = "pull_request" ]; then
    COMMIT_RANGE="HEAD~.."
  fi
  echo $COMMIT_RANGE > commit_range.txt

  if [ ! -z $COMMIT_RANGE ]; then
    PLANEMO_COMMIT_RANGE="--changed_in_commit_range $COMMIT_RANGE"
  fi

  planemo ci_find_repos $PLANEMO_COMMIT_RANGE --exclude packages --exclude deprecated --exclude_from .tt_skip --output repository_list.txt
  REPOSITORIES=$(cat repository_list.txt)

  touch tool_list.txt
  if [ -s repository_list.txt ]; then
    planemo ci_find_tools --output tool_list.txt $(cat repository_list.txt)
  fi

  NCHUNKS=$(wc -l < tool_list.txt)
  if [ "$NCHUNKS" -gt "$MAX_CHUNKS" ]; then
    NCHUNKS=$MAX_CHUNKS
  elif [ "$NCHUNKS" -eq 0 ]; then
    NCHUNKS=1
  fi
  echo $NCHUNKS > nchunks.txt
else
  echo "$REPOSITORIES" > repository_list.txt
  echo "$COMMIT_RANGE" > commit_range.txt
  echo "$NCHUNKS" > nchunks.txt
fi

if [ "$PLANEMO_LINT_TOOLS" == "true" ]; then
  while read -r DIR; do
    planemo shed_lint --tools --ensure_metadata --urls --report_level warn --fail_level error --recursive "$DIR";
  done < $(cat repository_list.txt)
fi

if [ "$PLANEMO_TEST_TOOLS" == "true" ]; then
  # Find tools
  touch changed_repositories_chunk.list changed_tools_chunk.list
  if [ $(wc -l < repository_list.txt) -eq 1 ]; then
      planemo ci_find_tools --chunk_count "$CHUNK_COUNT" --chunk "$CHUNK" \
                     --output changed_tools_chunk.list \
                     $(cat repository_list.txt)
  else
      planemo ci_find_repos --chunk_count "$CHUNK_COUNT" --chunk "$CHUNK" \
                     --output changed_repositories_chunk.list \
                     $(cat repository_list.txt)
  fi

  # show tools
  cat changed_tools_chunk.list changed_repositories_chunk.list
  # test tools
  if grep -lqf .tt_biocontainer_skip changed_tools_chunk.list changed_repositories_chunk.list; then
          PLANEMO_OPTIONS=""
  else
          PLANEMO_OPTIONS="--biocontainers --no_dependency_resolution --no_conda_auto_init"
  fi
  if [ -s changed_tools_chunk.list ]; then
      PIP_QUIET=1 planemo test --galaxy_python_version "$PYTHON_VERSION" --database_connection "$DATABASE_CONNECTION" $PLANEMO_OPTIONS --galaxy_source $GALAXY_REPO --galaxy_branch $GALAXY_RELEASE --test_output_json test_output.json $(cat changed_tools_chunk.list) || true
      docker system prune --all --force --volumes || true
  elif [ -s changed_repositories_chunk.list ]; then
      while read -r DIR; do
          if [[ "$DIR" =~ ^data_managers.* ]]; then
              TESTPATH=$(planemo ci_find_tools "$DIR")
          else
              TESTPATH="$DIR"
          fi
          PIP_QUIET=1 planemo test --galaxy_python_version "$PYTHON_VERSION" --database_connection "$DATABASE_CONNECTION" $PLANEMO_OPTIONS --galaxy_source $GALAXY_REPO --galaxy_branch $GALAXY_RELEASE --test_output_json "$DIR"/test_output.json "$TESTPATH" || true
          docker system prune --all --force --volumes || true
      done < changed_repositories_chunk.list
  else
      echo '{"tests":[]}' > test_output.json
  fi
fi

if [ "$PLANEMO_COMBINE_OUTPUTS" == "true" ]; then
  find . -name test_output.json -exec sh -c 'planemo merge_test_reports "$@" test_output.json' sh {} +
  [ ! -d upload ] && mkdir upload
  mv test_output.json upload/
  [ "$PLANEMO_HTML_REPORT" == "true" ] && planemo test_reports upload/test_output.json --test_output upload/test_output.html
  [ "$PLANEMO_MD_REPORT" == "true" ] && planemo test_reports upload/test_output.json --test_output_markdown upload/test_output.md
fi

if [ "$PLANEMO_DEPLOY" == "true" ]; then
   while read -r DIR; do
       planemo shed_update --shed_target "$SHED_TARGET" --shed_key "$SHED_KEY" --force_repository_creation "$DIR" || exit 1;
   done < repository_list.txt
fi
