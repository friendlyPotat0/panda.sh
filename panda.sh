#!/bin/bash

set -uo pipefail
IFS=$'\n'

bold=$(tput bold)
sgr0=$(tput sgr0)

declare -A program_data
source_directory=""
target_directory=""
declare -a pandoc_options
declare -a subdirectories
subdirectories_handlement=""

declare -a checksum_file_pair_collection_to_store
checksum_file_pair_collection_to_store_nth_element=""
declare -a stored_checksum_file_pair_collection
declare -a mismatched_checksum_files
declare -a scanned_rootless_files_to_render

### CHECK DEPENDENCIES ###

# assumes you have installed coreutils and findutils; therefore, dependencies within said packages are not checked
check_dependencies() {
    local missing_dependencies_count=0
    local dependencies=(
        "pandoc"
        "jq"
    )
    for dependency in "${dependencies[@]}"; do
        if ! command -v "$dependency" > /dev/null; then
            echo "${bold}$dependency${sgr0} not found"
            missing_dependencies_count=$((missing_dependencies_count + 1))
        fi
    done
    if [ "$missing_dependencies_count" -gt 0 ]; then
        echo "${bold}ERROR:${sgr0} Install missing dependencies before running this program"
        exit
    fi
}

### PROGRAM DATA MANAGEMENT ###

### STORE DATA

store_source_directory() {
    read -rep "Enter source directory: " source_directory # -e => Enables autocompletion
    source_directory="${source_directory%/*}"             # Remove trailing slashes
    program_data["source_directory"]="$source_directory"
}

store_target_directory() {
    read -rep "Enter target directory: " target_directory
    target_directory="${target_directory%/*}"
    program_data["target_directory"]="$target_directory"
}

store_pandoc_options() {
    tput dim
    readarray -t pandoc_options
    tput sgr0
    IFS=' ' program_data["pandoc_options"]="${pandoc_options[*]}" # Join array elements on declared IFS
}

store_subdirectories() {
    tput dim
    readarray -t subdirectories
    tput sgr0
    IFS=' ' program_data["subdirectories"]="${subdirectories[*]}"
}

store_subdirectories_handlement() {
    subdirectories_handlement="$1"
    program_data["subdirectories_handlement"]="$subdirectories_handlement"
}

### LOAD DATA

load_source_directory() {
    source_directory="$(jq --raw-output '.source_directory//empty' .panda/data.json)" # --raw-output => removes quotes from output, //empty => returns empty string instead of *null*
}

load_target_directory() {
    target_directory="$(jq --raw-output '.target_directory//empty' .panda/data.json)"
}

load_pandoc_options() {
    mapfile -d ' ' -t pandoc_options < <(jq --raw-output '.pandoc_options//empty' .panda/data.json) # -d ' ' => ("-foo -bar -baz") -> ("-foo" "-bar" "-baz")
}

load_subdirectories() {
    mapfile -d ' ' -t subdirectories < <(jq --raw-output '.subdirectories//empty' .panda/data.json)
}

load_subdirectories_handlement() {
    subdirectories_handlement="$(jq --raw-output '.subdirectories_handlement//empty' .panda/data.json)"
}

### MAIN

store_or_load_program_data() {
    if [ -z "$(ls .panda 2> /dev/null)" ]; then # is .panda/ empty?
        store_source_directory
        store_target_directory

        mkdir -p .panda

        local pandoc_options_provided
        read -rp "Provide pandoc options? [y/N]: " pandoc_options_provided
        [ "${pandoc_options_provided,,}" == "y" ] && store_pandoc_options

        local subdirectories_provided
        read -rp "Include[i]/Exclude[e] specific subdirectories? [N]: " subdirectories_provided
        case "${subdirectories_provided,,}" in
            i)
                store_subdirectories
                store_subdirectories_handlement "included"
                ;;
            e)
                store_subdirectories
                store_subdirectories_handlement "excluded"
                ;;
            *) store_subdirectories_handlement "" ;;
        esac

        jq --indent 4 -n '[$ARGS.positional | _nwise(2) | {(.[0]): .[1]}] | add' --args -- "${program_data[@]@k}" > .panda/data.json # https://stackoverflow.com/a/73862706

        echo
    else
        load_source_directory
        load_target_directory
        load_pandoc_options
        load_subdirectories
        load_subdirectories_handlement
    fi
}

### LOAD CHECKSUM DATA ###

load_checksum_data() {
    mapfile -t stored_checksum_file_pair_collection < <(cat .panda/sha256sum.txt 2> /dev/null)
    mapfile -t mismatched_checksum_files < <(sha256sum --quiet -c .panda/sha256sum.txt |& grep -i 'FAILED' | awk -F ':' '{ print $1 }') # path/to/file.md: FAILED -> path/to/file.md
}

### LOAD MARKDOWN DATA ###

load_markdown_data() {
    local scan_parameters
    case "$subdirectories_handlement" in
        "included") scan_parameters="$(printf -- "-path '*%s*' -type f -name '*.md' -printf '%%P\\\n' -or " "${subdirectories[@]}" | sed 's| -or $||g' | tr -d '\n')" ;;
        "excluded") scan_parameters="$(printf -- "-not -path '*%s*' -type f -name '*.md' -printf '%%P\\\n' " "${subdirectories[@]}" | sed 's| $||g' | tr -d '\n')" ;;
        *) scan_parameters="-type f -name '*.md' -printf '%P\n'" ;;
    esac
    mapfile -t scanned_rootless_files_to_render < <(eval find "$source_directory" "$scan_parameters") # -printf '%P\n' => $source/path/to/file.md -> path/to/file.md
}

### INSPECT VARIABLE INTEGRITY ###

inspect_variable_integrity() {
    local anomalous_variable_count=0
    if [ -z "$source_directory" ]; then
        echo "${bold}ERROR:${sgr0} Source directory not set"
        ((anomalous_variable_count++))
    fi
    if [ -z "$target_directory" ]; then
        echo "${bold}ERROR:${sgr0} Target directory not set"
        ((anomalous_variable_count++))
    fi
    if [ "${#scanned_rootless_files_to_render[@]}" -eq 0 ]; then
        echo "${bold}ERROR:${sgr0} Couldn't find markdown files under source directory"
        ((anomalous_variable_count++))
    fi
    [ "$anomalous_variable_count" -gt 0 ] && exit
}

### RENDER PDF ###

does_pdf_exist() {
    [ -f "$1" ] && return 0 || return 1
}

# checks if given file has a corresponding checksum stored in .panda/sha256sum.txt
does_checksum_exist() {
    [ "${#stored_checksum_file_pair_collection[@]}" -eq 0 ] && return 1 # is .panda/sha256sum.txt empty?
    for stored_checksum_file_pair in "${stored_checksum_file_pair_collection[@]}"; do
        if [ "$1" == "${stored_checksum_file_pair#*'  '}" ]; then # <checksum>  path -> path
            checksum_file_pair_collection_to_store+=("$stored_checksum_file_pair")
            checksum_file_pair_collection_to_store_nth_element="$1"
            return 0
        fi
    done
    return 1
}

# checks if given file belongs to collection of files with checksum mismatch
has_file_been_modified() {
    for mismatched_checksum_file in "${mismatched_checksum_files[@]}"; do
        [ "$1" == "$mismatched_checksum_file" ] && return 0
    done
    return 1
}

### MAIN

render_pdf() {
    local up_to_date_documents=0
    for scanned_rootless_file_to_render in "${scanned_rootless_files_to_render[@]%.*}"; do # path/to/file.md -> path/to/file
        if ! does_pdf_exist "$target_directory/$scanned_rootless_file_to_render.md.pdf" ||
            ! does_checksum_exist "$source_directory/$scanned_rootless_file_to_render.md" ||
            has_file_been_modified "$source_directory/$scanned_rootless_file_to_render.md"; then

            echo "CONVERTING: $scanned_rootless_file_to_render.md"

            local rootless_directory_structure_of_file_to_render
            rootless_directory_structure_of_file_to_render="$(dirname "$scanned_rootless_file_to_render")" # path/to/file -> path/to
            mkdir -p "$target_directory/$rootless_directory_structure_of_file_to_render"

            tput dim
            # shellcheck disable=2048,2086
            if eval pandoc -t pdf --pdf-engine=tectonic --resource-path=\'"$source_directory/$rootless_directory_structure_of_file_to_render"\' ${pandoc_options[*]} --output=\'"$target_directory/$scanned_rootless_file_to_render.md.pdf"\' \'"$source_directory/$scanned_rootless_file_to_render.md"\'; then # \'"foo bar baz"\' --eval-> 'foo bar baz'
                if [ "$checksum_file_pair_collection_to_store_nth_element" == "$source_directory/$scanned_rootless_file_to_render.md" ]; then
                    checksum_file_pair_collection_to_store["$((${#checksum_file_pair_collection_to_store[@]} - 1))"]="$(sha256sum "$source_directory/$scanned_rootless_file_to_render.md")" # overwrite stored checksum
                else
                    checksum_file_pair_collection_to_store+=("$(sha256sum "$source_directory/$scanned_rootless_file_to_render.md")") # add checksum
                fi
            fi
            tput sgr0
        else
            ((up_to_date_documents++))
        fi
    done
    if [ "${#scanned_rootless_files_to_render[@]}" -eq "$up_to_date_documents" ]; then
        echo "Documents are up to date!"
    else
        printf '%s\n' "${checksum_file_pair_collection_to_store[@]}" > .panda/sha256sum.txt # update stored checksums
    fi
}

check_dependencies
store_or_load_program_data
load_checksum_data
load_markdown_data
inspect_variable_integrity
render_pdf
