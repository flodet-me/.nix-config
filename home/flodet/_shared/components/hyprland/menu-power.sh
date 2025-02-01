# Define options with icons (using Font Awesome icons)
OPTIONS="  Shutdown\n  Reboot\n  Suspend\n  Hibernate\n  Lock\n  Logout\n  Restart Hyprland"

# Display the menu using fuzzel
CHOICE=$(echo -e "$OPTIONS" | fuzzel -d --icon-theme "FontAwesome")

# Perform the selected action
case "$CHOICE" in
    *Shutdown) systemctl poweroff ;;
    *Reboot) systemctl reboot ;;
    *Suspend) systemctl suspend ;;
    *Hibernate) systemctl hibernate ;;
    *Lock) hyprlock ;;  # Replace with your preferred screen locker (e.g., swaylock, slock)
    *Logout) hyprctl dispatch exit ;;
    *Restart\ Hyprland) hyprctl reload ;;
esac
