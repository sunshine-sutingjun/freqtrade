#!/usr/bin/env bash
#encoding=utf8

function check_installed_uv() {
    # Add common uv installation paths to PATH
    export PATH="$HOME/.local/bin:$HOME/.cargo/bin:/root/.local/bin:$PATH"
    
    if ! command -v uv &> /dev/null; then
        echo_block "Installing uv"
        # Don't install if we're running as root and uv might already be installed for the user
        if [ "$EUID" -eq 0 ]; then
            echo "Warning: Running as root. uv should be installed for the user account."
            echo "Please run this script without sudo, or install uv manually:"
            echo "curl -LsSf https://astral.sh/uv/install.sh | sh"
            echo "Then add ~/.local/bin to your PATH"
            exit 1
        fi
        
        curl -LsSf https://astral.sh/uv/install.sh | sh
        export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
        
        if ! command -v uv &> /dev/null; then
            echo "Failed to install uv. Please install it manually from https://github.com/astral-sh/uv"
            echo "Run: curl -LsSf https://astral.sh/uv/install.sh | sh"
            echo "Then add ~/.local/bin to your PATH"
            exit 1
        fi
    fi
    echo "uv is available at: $(command -v uv)"
}

function echo_block() {
    echo "----------------------------"
    echo $1
    echo "----------------------------"
}

function check_installed_uv() {
    if ! command -v uv &> /dev/null; then
        echo_block "Installing uv"
        curl -LsSf https://astral.sh/uv/install.sh | sh
        export PATH="$HOME/.cargo/bin:$PATH"
        # Reload the shell to make uv available
        source ~/.bashrc 2>/dev/null || source ~/.zshrc 2>/dev/null || true
        if ! command -v uv &> /dev/null; then
            echo "Failed to install uv. Please install it manually from https://github.com/astral-sh/uv"
            exit 1
        fi
    fi
    echo "uv is available"
}

# Check which python version is installed and ensure uv is available
function check_installed_python() {
    if [ -n "${VIRTUAL_ENV}" ]; then
        echo "Please deactivate your virtual environment before running setup.sh."
        echo "You can do this by running 'deactivate'."
        exit 2
    fi

    check_installed_uv

    # uv will handle Python version detection and installation
    # Check if we can find a suitable Python version
    for v in 13 12 11
    do
        PYTHON="python3.${v}"
        if command -v $PYTHON &> /dev/null; then
            echo "Found ${PYTHON}"
            PYTHON_VERSION="3.${v}"
            return
        fi
    done

    echo "No usable python found. uv will install Python automatically."
    PYTHON_VERSION="3.11"  # Default to Python 3.11
}

function updateenv() {
    echo_block "Updating your virtual environment"
    if [ ! -f .venv/pyvenv.cfg ]; then
        echo "Something went wrong, no virtual environment found."
        exit 1
    fi
    
    SYS_ARCH=$(uname -m)
    echo "uv install in-progress. Please wait..."
    
    # Activate the virtual environment for uv
    source .venv/bin/activate
    
    REQUIREMENTS_FILES=()
    REQUIREMENTS=requirements.txt

    read -p "Do you want to install dependencies for development (Performs a full install with all dependencies) [y/N]? "
    dev=$REPLY
    if [[ $REPLY =~ ^[Yy]$ ]]
    then
        REQUIREMENTS=requirements-dev.txt
        REQUIREMENTS_FILES+=("$REQUIREMENTS")
    else
        REQUIREMENTS_FILES+=("$REQUIREMENTS")
        # requirements-dev.txt includes all the below requirements already, so further questions are pointless.
        read -p "Do you want to install plotting dependencies (plotly) [y/N]? "
        if [[ $REPLY =~ ^[Yy]$ ]]
        then
            REQUIREMENTS_FILES+=("requirements-plot.txt")
        fi
        if [ "${SYS_ARCH}" == "armv7l" ] || [ "${SYS_ARCH}" == "armv6l" ]; then
            echo "Detected Raspberry, installing cython, skipping hyperopt installation."
            uv pip install cython
        else
            # Is not Raspberry
            read -p "Do you want to install hyperopt dependencies [y/N]? "
            if [[ $REPLY =~ ^[Yy]$ ]]
            then
                REQUIREMENTS_FILES+=("requirements-hyperopt.txt")
            fi
        fi

        read -p "Do you want to install dependencies for freqai [y/N]? "
        if [[ $REPLY =~ ^[Yy]$ ]]
        then
            read -p "Do you also want dependencies for freqai-rl or PyTorch (~700mb additional space required) [y/N]? "
            if [[ $REPLY =~ ^[Yy]$ ]]
            then
                REQUIREMENTS_FILES+=("requirements-freqai-rl.txt")
            else
                REQUIREMENTS_FILES+=("requirements-freqai.txt")
            fi
        fi
    fi

    # Install requirements using uv
    for req_file in "${REQUIREMENTS_FILES[@]}"; do
        echo "Installing requirements from $req_file"
        uv pip install -r "$req_file"
        if [ $? -ne 0 ]; then
            echo "Failed installing dependencies from $req_file"
            exit 1
        fi
    done
    
    # Install freqtrade in editable mode
    uv pip install -e .
    if [ $? -ne 0 ]; then
        echo "Failed installing Freqtrade"
        exit 1
    fi

    echo "Installing freqUI"
    freqtrade install-ui

    echo "uv install completed"
    echo
    if [[ $dev =~ ^[Yy]$ ]]; then
        pre-commit install
        if [ $? -ne 0 ]; then
            echo "Failed installing pre-commit"
            exit 1
        fi
    fi
}

# Install bot MacOS
function install_macos() {
    if [ ! -x "$(command -v brew)" ]
    then
        echo_block "Installing Brew"
        /usr/bin/ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install)"
    fi

    brew install gettext libomp
    
    # uv will handle Python installation, no need to manually check version
}

# Install bot Debian_ubuntu
function install_debian() {
    sudo apt-get update
    sudo apt-get install -y gcc build-essential autoconf libtool pkg-config make wget git curl
    # uv will handle Python installation and virtual environments
}

# Install bot RedHat_CentOS
function install_redhat() {
    sudo yum update
    sudo yum install -y gcc gcc-c++ make autoconf libtool pkg-config wget git
    # uv will handle Python installation and development headers
}

# Upgrade the bot
function update() {
    git pull
    if [ -f .env/bin/activate  ]; then
        # Old environment found - updating to new environment.
        recreate_environments
    fi
    updateenv
    echo "Update completed."
    echo_block "Don't forget to activate your virtual environment with 'source .venv/bin/activate'!"

}

function check_git_changes() {
    if [ -z "$(git status --porcelain)" ]; then
        echo "No changes in git directory"
        return 1
    else
        echo "Changes in git directory"
        return 0
    fi
}

function recreate_environments() {
    if [ -d ".env" ]; then
        # Remove old virtual env
        echo "- Deleting your previous virtual env"
        echo "Warning: Your new environment will be at .venv!"
        rm -rf .env
    fi
    if [ -d ".venv" ]; then
        echo "- Deleting your previous virtual env"
        rm -rf .venv
    fi

    echo
    echo "Creating virtual environment with uv..."
    uv venv .venv --python "${PYTHON_VERSION}"
    if [ $? -ne 0 ]; then
        echo "Could not create virtual environment with uv. Leaving now"
        exit 1
    fi

}

# Reset Develop or Stable branch
function reset() {
    echo_block "Resetting branch and virtual env"

    if [ "1" == $(git branch -vv |grep -cE "\* develop|\* stable") ]
    then
        if check_git_changes; then
            read -p "Keep your local changes? (Otherwise will remove all changes you made!) [Y/n]? "
            if [[ $REPLY =~ ^[Nn]$ ]]; then

                git fetch -a

                if [ "1" == $(git branch -vv | grep -c "* develop") ]
                then
                    echo "- Hard resetting of 'develop' branch."
                    git reset --hard origin/develop
                elif [ "1" == $(git branch -vv | grep -c "* stable") ]
                then
                    echo "- Hard resetting of 'stable' branch."
                    git reset --hard origin/stable
                fi
            fi
        fi
    else
        echo "Reset ignored because you are not on 'stable' or 'develop'."
    fi
    recreate_environments

    updateenv
}

function config() {
    echo_block "Please use 'freqtrade new-config -c user_data/config.json' to generate a new configuration file."
}

function install() {

    echo_block "Installing mandatory dependencies"

    if [ "$(uname -s)" == "Darwin" ]; then
        echo "macOS detected. Setup for this system in-progress"
        install_macos
    elif [ -x "$(command -v apt-get)" ]; then
        echo "Debian/Ubuntu detected. Setup for this system in-progress"
        install_debian
    elif [ -x "$(command -v yum)" ]; then
        echo "Red Hat/CentOS detected. Setup for this system in-progress"
        install_redhat
    else
        echo "This script does not support your OS."
        echo "If you have Python version 3.11 - 3.13, pip, virtualenv installed you can continue."
        echo "Wait 10 seconds to continue the next install steps or use ctrl+c to interrupt this shell."
        sleep 10
    fi
    echo
    reset
    config
    echo_block "Run the bot !"
    echo "You can now use the bot by executing 'source .venv/bin/activate; freqtrade <subcommand>'."
    echo "You can see the list of available bot sub-commands by executing 'source .venv/bin/activate; freqtrade --help'."
    echo "You verify that freqtrade is installed successfully by running 'source .venv/bin/activate; freqtrade --version'."
    echo "Note: This setup now uses uv for faster Python package management."
}

function plot() {
    echo_block "Installing dependencies for Plotting scripts"
    if [ -f .venv/bin/activate ]; then
        source .venv/bin/activate
        uv pip install plotly
    else
        echo "No virtual environment found. Please run setup first."
        exit 1
    fi
}

function help() {
    echo "usage:"
    echo "	-i,--install    Install freqtrade from scratch"
    echo "	-u,--update     Command git pull to update."
    echo "	-r,--reset      Hard reset your develop/stable branch."
    echo "	-c,--config     Easy config generator (Will override your existing file)."
    echo "	-p,--plot       Install dependencies for Plotting scripts."
}

# Verify if 3.11+ is installed and setup uv
check_installed_python

case $* in
--install|-i)
install
;;
--config|-c)
config
;;
--update|-u)
update
;;
--reset|-r)
reset
;;
--plot|-p)
plot
;;
*)
help
;;
esac
exit 0
