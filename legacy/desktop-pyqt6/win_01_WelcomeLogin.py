from PyQt6.QtWidgets import (
    QApplication,
    QMainWindow,
    QWidget,
    QLabel,
    QLineEdit,
    QPushButton,
    QVBoxLayout,
    QMessageBox,
)
from PyQt6.QtGui import QPixmap, QFont, QIcon
from PyQt6.QtCore import Qt
from PyQt6.QtGui import QGuiApplication

# import the necessary modules from other windows
from win_02_1_CusServDashboard import cusServDashboard
from win_02_2_HRDashboard import hrDashboard

# other modules
import cx_Oracle
# import qdarktheme
import sys
import os
import configparser


# https://stackoverflow.com/a/31966932
def resource_path(relative_path):
    """Get absolute path to resource, works for dev and for PyInstaller"""
    try:
        # PyInstaller creates a temp folder and stores path in _MEIPASS
        base_path = sys._MEIPASS2
    except Exception:
        base_path = os.path.abspath(".")

    return os.path.join(base_path, relative_path)


class welcome(QMainWindow):
    def __init__(self):
        super().__init__()

        # set the window title
        windowTitle = "WEL Bank"
        self.setWindowTitle(windowTitle)

        # set WINDOW ICON (icons from icons8.com)
        self.setWindowIcon(QIcon(resource_path("./assets/bank.png")))

        # Set cream color for the background
        # self.setStyleSheet("background-color: #HEXcode")

        # Set window size
        width = 800
        height = 600
        self.resize(width, height)

        # center the window, center function defined below
        self.center()

        # Good practice to use a member of another class
        # initialize members of other classes to None
        self.cusServDashboard = None
        self.hrDashboard = None

        # create the user interface
        # self.initUI()

        # user interface function
        # def initUI(self):
        """
        Initializes the customers window.
        """
        ######################### CREATE WIDGETS #########################
        # self.welcomeLabel = QLabel("Welcome to WEL Bank")
        # self.welcomeLabel.setFont(QFont("Century", 28))
        # Adding a logo
        logo = QPixmap(
            resource_path("./assets/WEL_Bank-logos_transparent_greentext_300x300.png")
        )
        logolabel = QLabel()
        logolabel.setPixmap(logo)
        logolabel.setAlignment(Qt.AlignmentFlag.AlignCenter)

        # Username
        usernameLabel = QLabel("Username")
        self.usernameField = QLineEdit()
        self.usernameField.setPlaceholderText("Username")

        # Password
        passwordLabel = QLabel("Password")
        self.passwordField = QLineEdit()
        self.passwordField.setPlaceholderText("Enter your password")
        self.passwordField.setEchoMode(QLineEdit.EchoMode.Password)

        # Login as
        loginasLabel = QLabel("Login as")
        loginasLabel.setAlignment(Qt.AlignmentFlag.AlignCenter)

        # Read settings from the config file
        config = configparser.ConfigParser()
        config_path = resource_path("config.ini")
        config.read(config_path)
        # Connection settings
        ip = config.get("oracle", "host")
        port = config.get("oracle", "port")
        service_name = config.get("oracle", "service_name")

        self.usn = config.get("oracle", "admin_user")
        self.pwd = config.get("oracle", "password")
        self.dsn = cx_Oracle.makedsn(
            ip, port, service_name=service_name
        )  # https://stackoverflow.com/a/39984489

        cs_dept_ids = [
            int(id.strip()) for id in config.get("database", "cs_dept_ids").split(",")
        ]
        hr_dept_ids = [
            int(id.strip()) for id in config.get("database", "hr_dept_ids").split(",")
        ]

        # For Login buttons functions
        # CUSTOMER SERVICE employees usernames
        cusServ_dep_usn = self.get_usernames(cs_dept_ids)
        # add default users
        cusServ_dep_usn.extend(
            [config.get("oracle", "admin_user"), config.get("oracle", "cs_user")]
        )
        """cusServ_dep_usn = [
            "welbank",
            "cs",
            "kwameowusu",
        ]"""

        # HR employees usernames
        hr_dep_usn = self.get_usernames(hr_dept_ids)
        # add default users
        hr_dep_usn.extend(
            [config.get("oracle", "admin_user"), config.get("oracle", "hr_user")]
        )
        """hr_dep_usn = [
            "welbank",
            "hr",
            "kwadwohanson",
        ]"""

        # customer Service login Button
        cusServloginButton = QPushButton("Customer Service", clicked=lambda: self.login("cusServDashboard", cusServ_dep_usn))  # type: ignore
        # Human Resource login Button
        HRloginButton = QPushButton("Human Resources", clicked=lambda: self.login("hrDashboard", hr_dep_usn))  # type: ignore

        # About & Get Help widgets
        aboutButton = QPushButton("About", clicked=lambda: self.about())  # type: ignore
        getHelpButton = QPushButton("Get Help", clicked=lambda: self.help())  # type: ignore
        ######################################################### END OF WIDGETS CREATION #########################################################

        ############################ LAYOUT ############################
        layout = QVBoxLayout()

        # Add a spacer
        # layout.addStretch()

        ### ADD WIDGETS TO LAYOUT ###
        # layout.addWidget(welcomeLabel)
        layout.addWidget(logolabel)
        layout.addSpacing(10)
        layout.addWidget(usernameLabel)
        layout.addWidget(self.usernameField)
        layout.addWidget(passwordLabel)
        layout.addWidget(self.passwordField)
        layout.addWidget(loginasLabel)
        layout.addWidget(cusServloginButton)
        layout.addWidget(HRloginButton)
        layout.addSpacing(10)

        # set layout
        nestedlayout = QVBoxLayout()
        nestedlayout.addWidget(aboutButton)
        nestedlayout.addWidget(getHelpButton)
        # align layout to the bottom right
        nestedlayout.setAlignment(
            Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignBottom
        )

        # add nested layout to main layout
        layout.addStretch(1)  # push the widget to the bottom
        layout.addLayout(nestedlayout)

        ### SET CONTENT MARGINS ###
        layout.setContentsMargins(200, 30, 200, 50)  # left, top, right, bottom

        ### Center window content ###
        container = QWidget()
        container.setLayout(layout)
        self.setCentralWidget(container)
        ####################################

        ############## Status Bar ##############
        # show message in the status bar
        self.statusBar().showMessage("Ready...")  # type: ignore
        ########################################

        # Other settings

        # print(self.dsn, self.usn, self.pwd, sep="\n")

    ##################### BUTTON FUNCTIONS #####################
    # LOGIN BUTTON FUNCTION
    def login(self, dashboard: str, dep_usn: list):

        # Grab text in the fields
        self.username = self.usernameField.text()
        self.password = self.passwordField.text()  # should probably be encrypted

        # set the appropriate dashboard and second department name
        if dashboard == "cusServDashboard":
            dashboard = cusServDashboard()
            otherdep = "Human Resources"
        elif dashboard == "hrDashboard":
            dashboard = hrDashboard()
            otherdep = "Customer Service"

        # initialise connection
        connection = None
        try:
            connection = cx_Oracle.connect(
                user=self.username, password=self.password, dsn=self.dsn
            )
        except cx_Oracle.Error as err:
            QMessageBox.critical(
                self,
                "Database Connection Error",
                str(err)
                + "\n"
                + "Failed to connect to database"
                + "\n"
                + "Please contact the database administrator",
            )
        else:
            if connection:
                if self.username in dep_usn:
                    self.hide()
                    dashboard.show()
                    QMessageBox.information(self, "Login", "Login successful")
                else:
                    QMessageBox.warning(
                        self,
                        "Login Error",
                        f"You are not authorized to access this section. You may login as a {otherdep} employee!",
                    )
        finally:
            if connection is not None:
                connection.close()

    # About button
    def about(self):
        QMessageBox.information(
            self, "About", "Version 2.0" + "\n" + "This is the About section"
        )

    # Help button
    def help(self):
        QMessageBox.information(
            self,
            "Help",
            "This is the Help section" + "\n" + "Contact the IT Department",
        )

    ##################### END OF BUTTON FUNCTIONS #####################

    # _______________________________________________________________
    # SECONDARY METHODS
    def get_usernames(self, dep_id: list):

        # Create a connection and cursor
        connection = cx_Oracle.connect(user=self.usn, password=self.pwd, dsn=self.dsn)
        cursor = connection.cursor()

        # Execute the SQL query
        cursor.execute(
            f"SELECT username FROM employees WHERE dep_id IN ({', '.join(map(str, map(int, dep_id)))})"
        )

        # Fetch the results from the query
        results = cursor.fetchall()

        # Close the cursor and connection
        cursor.close()
        connection.close()

        # Extract the usernames from the results
        usernames = [result[0] for result in results]

        return usernames

    ##################### CENTER WINDOW FUNCTION #####################
    def showEvent(self, event):
        self.center()
        super().showEvent(event)

    def center(self):
        frame = self.frameGeometry()
        screen = QGuiApplication.primaryScreen()
        center = screen.availableGeometry().center()  # type: ignore
        frame.moveCenter(center)
        x = min(frame.topLeft().x(), screen.availableGeometry().right() - frame.width())  # type: ignore
        y = min(frame.topLeft().y(), screen.availableGeometry().bottom() - frame.height())  # type: ignore
        self.move(x, y)

    ############################# END OF CENTER WINDOW FUNCTION #############################


if __name__ == "__main__":
    try:
        # Include in try/except block if also targeting Mac/Linux
        from ctypes import windll  # only exists on Windows

        myappid = "mycompany.myproduct.subproduct.version"
        windll.shell32.SetCurrentProcessExplicitAppUserModelID(myappid)
    except ImportError:
        pass
    finally:
        # create the QApplication object
        app = QApplication(sys.argv)

        # create the main window (an instance of of the welcome class)
        welcomewindow = welcome()

        # show the window
        welcomewindow.show()

        # DARK THEME (https://pypi.org/project/pyqtdarktheme/)
        # qdarktheme.setup_theme("auto")

        # start the event loop
        sys.exit(app.exec())
