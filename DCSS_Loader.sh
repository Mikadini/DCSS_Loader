#!/bin/bash

# Save the starting directory (where the script was executed)
origin_dir="$(pwd)"

# Function to compare two versions using sort -V.
# Returns 0 if $1 > $2, otherwise 1.
version_gt() {
    if [[ "$(printf "%s\n%s" "$1" "$2" | sort -V | head -n1)" == "$2" && "$1" != "$2" ]]; then
        return 0
    else
        return 1
    fi
}

# Variabile per determinare se siamo in una prima installazione
first_install=false

# Check if the LastVersion.txt file exists in the current directory
if [ ! -f "LastVersion.txt" ]; then
    first_install=true
    # File doesn't exist: ask the user if they want to download the game.
    read -r -p "No previous Version Found. Do you want to download the game? [Y/n] " answer
    answer=${answer:-Y}

    case "$answer" in
        [nN]* )
            echo "Aborting."
            exit 1
            ;;
        * )
            # Set current_version to "0" to consider any numeric tag as updated
            current_version="0"
            echo "Proceeding with current_version set to $current_version."
            ;;
    esac
else
    # Read the file content and remove any whitespace
    current_version=$(tr -d '[:space:]' < LastVersion.txt)
    if [ -z "$current_version" ]; then
        echo "Error: LastVersion.txt is empty."
        exit 1
    fi
    echo "Current version read from file: $current_version"
fi

# Set the remote repository
remote_repo="https://github.com/crawl/crawl.git"
echo "Retrieving remote tags from $remote_repo ..."

# Retrieve remote tags (extracting tag names from references)
remote_tags=$(git ls-remote --tags "$remote_repo" | awk '{print $2}' | sed 's|refs/tags/||')

if [ -z "$remote_tags" ]; then
    echo "Error: Unable to retrieve tags from remote repository."
    exit 1
fi

# Array to hold candidate tags that meet the format and are greater than current_version
candidate_tags=()

for tag in $remote_tags; do
    # Ignore tags that contain the letter "a" (case-insensitive)
    if echo "$tag" | grep -qi "a"; then
        continue
    fi

    # Only consider tags composed exclusively of numbers and dots (e.g., 0.32.1)
    if ! [[ "$tag" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
        continue
    fi

    # If the tag is greater than current_version, add it to the array
    if version_gt "$tag" "$current_version"; then
        candidate_tags+=("$tag")
    fi
done

# Se non vi è nessun tag maggiore, il gioco è già aggiornato.
if [ ${#candidate_tags[@]} -eq 0 ]; then
    echo "The game is already updated."
    # Chiedi all'utente se vuole caricare il file custom MyInit.txt
    read -r -p "Do you want to load your custom Init file? [y/N] " load_init_answer
    load_init_answer=${load_init_answer:-N}
    if [[ "$load_init_answer" =~ ^[Yy]$ ]]; then
        # Supponiamo che la directory di installazione esistente sia nominata "DCSS_Version_<current_version>"
        existing_install_dir="DCSS_Version_$current_version"
        if [ ! -d "$existing_install_dir" ]; then
            echo "Error: Installation directory '$existing_install_dir' not found. Cannot update custom Init file."
        else
            settings_dir="$existing_install_dir/crawl-ref/settings"
            target_init_file="$settings_dir/init.txt"
            if [ ! -d "$settings_dir" ]; then
                echo "Error: Settings directory '$settings_dir' not found."
            else
                if [ ! -f "MyInit.txt" ]; then
                    echo "Error: 'MyInit.txt' not found. Please modify the file directly in the 'settings' folder and next time save it under that name in the 'Master' folder so that your customized file will be available in future updates."
                else
                    echo "Replacing $target_init_file with your custom Init file..."
                    # Copia e rinomina il file custom
                    cp "MyInit.txt" "$settings_dir/MyInit.txt"
                    mv "$settings_dir/MyInit.txt" "$target_init_file"
                    echo "Custom initialization file replaced successfully."
                fi
            fi
        fi
    fi
    exit 0
fi

# Find the maximum tag (the highest version) among the candidates
max_tag=$(printf "%s\n" "${candidate_tags[@]}" | sort -rV | head -n 1)

# Se il tag massimo è uguale alla versione corrente, il gioco è già aggiornato.
if [ "$max_tag" = "$current_version" ]; then
    echo "The game is already updated."
    # (Opzionale) Qui potresti ripetere la logica del prompt per il MyInit.txt se lo desideri
    exit 0
fi

echo "Found a newer version: $max_tag"

# Se non si tratta di una prima installazione, chiede se aggiornare, altrimenti procede automaticamente.
if [ "$first_install" = false ]; then
    read -r -p "A new version ($max_tag) is available. Do you want to update the game? [Y/n] " update_answer
    update_answer=${update_answer:-Y}
    if [[ "$update_answer" =~ ^[Nn] ]]; then
        echo "Update cancelled."
        exit 0
    fi
else
    echo "First installation detected; proceeding with update without asking."
fi

# Use the specified command to clone the repository with the specific tag
clone_dir="crawl_clone_temp"
echo "Cloning branch/tag $max_tag from remote repository..."
git clone --branch "$max_tag" --depth 1 "$remote_repo" "$clone_dir"
if [ $? -ne 0 ]; then
    echo "Error: Failed to clone repository with tag $max_tag."
    exit 1
fi

# Execute the required commands inside the cloned folder
cd "$clone_dir" || { echo "Error: Directory $clone_dir not found."; exit 1; }
echo "Updating submodules..."
git submodule update --init

if [ ! -d "crawl-ref/source" ]; then
    echo "Error: Directory crawl-ref/source not found."
    exit 1
fi

cd crawl-ref/source || { echo "Error: Cannot change directory to crawl-ref/source."; exit 1; }
echo "Executing: make -j4 TILES=y"
make -j4 TILES=y

# Return to the cloned directory and then to the container folder
cd ../.. || { echo "Error: Returning to clone root failed."; exit 1; }
# Return to the origin directory
cd "$origin_dir" || { echo "Error: Cannot return to origin directory."; exit 1; }

# Renaming of the cloned folder (performed before the prompt for the INIT file)
new_dir="DCSS_Version_$max_tag"
mv "$clone_dir" "$new_dir"

# Update (or create) the LastVersion.txt file with the latest tag version
echo "$max_tag" > LastVersion.txt
echo "LastVersion.txt updated with version $max_tag."

# New feature: ask the user if they want to load their custom Init file.
read -r -p "Do you want to load your custom Init file? [Y/n] " load_init_answer
load_init_answer=${load_init_answer:-Y}

if [[ "$load_init_answer" =~ ^[Yy]$ ]]; then
    # Check if the 'MyInit.txt' file exists
    if [ ! -f "MyInit.txt" ]; then
        echo "Error: 'MyInit.txt' not found. Please modify the file directly in the 'settings' folder and next time save the file under that name in the 'Master' folder so that your customized file will be available in future updates."
    else
        # Set the destination directory for the init file
        settings_dir="$new_dir/crawl-ref/settings"
        target_init_file="$settings_dir/init.txt"
        if [ ! -d "$settings_dir" ]; then
            echo "Error: Settings directory '$settings_dir' not found."
        else
            echo "Replacing $target_init_file with your custom Init file..."
            # Copy the custom file to a temporary location within the settings folder
            cp "MyInit.txt" "$settings_dir/MyInit.txt"
            # Rename the newly copied file to init.txt, replacing the existing one
            mv "$settings_dir/MyInit.txt" "$target_init_file"
            echo "Custom initialization file replaced successfully."
        fi
    fi
fi

echo "Cloning, build and customization complete. Repository cloned and renamed as: '$new_dir'."
