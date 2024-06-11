
# AnySense
AnySense was developed in Xcode SwiftUI. This is an iPhone-based application that integrates the iPhone's sensory suite with external multisensory inputs via Bluetooth and wired interfaces, enabling both offline data collection and online streaming to robots. 
*****
AnySense data storage format:
    - Streamed Tactile Data (.txt)
    - RGB video frames (.mp4)  
    - Depth video frames (.mp4)
    - RGB images (.png)
    - Depth images (.png)
    - Pose Data (.txt)

## Requirements and setting-up to open in Xcode
1. Install the latest version of Xcode: https://developer.apple.com/xcode/, in the GitHub, use git clone.

2. After the system automatically directs you to the Xcode, press "trust and open", to save it on your computer. Make sure you are in the SwiftUI developing environment.

   
## Connect to your iPhone as a Xcode developer
The published version has not been finished yet since we didn't apply to publish this app to the app store. So it can only connect to the developer's device through Xcode support. 
1. In your "Signing & Capabilities" section of the app, make sure the "Automatically manage signing" checkbox is checked.
<img width="1378" alt="截屏2024-06-12 13 09 02" src="https://github.com/MMMMMaasd/reskin_bluetooth_app/assets/166888204/c5e72148-3862-4cc9-96ba-5078061c0ef9">

2. Press command + "," to open the Accounts setting, in the Accounts section, press the bottom left plus button and add your Apple ID to it.
<img width="825" alt="截屏2024-06-12 13 11 53" src="https://github.com/MMMMMaasd/reskin_bluetooth_app/assets/166888204/556e6cbb-b03d-442f-b2f9-65e430773953">

3. Rename your Bundle Identifier to whatever you want, I highly recommend renaming it to youRname.AnySense
   
3. Now plug in your IOS device to your Mac that opened with the Xcode project, and make sure to trust this computer when it pops out on your phone.
   
4. In the picking simulator section, Xcode will automatically display your local device, click it and follow the instructions popped out by Xcode.
<img width="1105" alt="截屏2024-06-12 13 13 06" src="https://github.com/MMMMMaasd/reskin_bluetooth_app/assets/166888204/d3862d94-8379-4018-8791-836b685f2870">

5. Xcode will certainly warn you to change your iPhone to developer mode, change it to develop mode, and then re-open your device (How to change to develop mode? https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device), now you should be able to connect!
 
6. Important: This way of connection will only create a temporary version of this app, it will be disabled after the next few days. You need to re-simulate the app to keep track of it. 

## Contact me
Questions about AnySense? Contact: raunaqbhirangi@nyu.edu

App designed by the Generalizable Robotics and AI Lab, NYU:
Raunaq Bhirangi, Zeyu (Michael) Bian, Venkatesh Pattabiraman, Haritheja Etukuru, Mehmet Enes Erciyes, Nur Muhammad Mahi Shafiullah, Lerrel Pinto 
