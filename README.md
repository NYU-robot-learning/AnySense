
# AnySense
[AnySense](https://anysense.app) is an open-source iPhone app that enables multi-sensory data collection by integrating the iPhone's sensory suite with external sensors via Bluetooth and wired interfaces, enabling both offline data collection and online streaming to robots. The app also supports on-device policy evaluation: you can load a trained CoreML policy, set a 3D goal in AR, and run the policy with AR visualization of predicted actions without a robot. We record RGB and depth videos, metric depth frames, streamed Bluetooth data (e.g. from tactile sensors) into a binary file, and timestamped pose data as a `.txt` file. Example streaming code for Bluetooth data can be found on [AnySkin](https://any-skin.github.io). USB streaming is supported by connecting the iPhone to your computer and using this [accompanying library](https://github.com/NYU-robot-learning/anysense-streaming) (forked from [record3d](https://github.com/marek-simonik/record3d)).

## App Screenshots
<img src="https://github.com/user-attachments/assets/12e760dc-a1ea-4f91-b67b-9e803ad643cb" width=200px alt="sdfasdf" />
<img src="https://github.com/user-attachments/assets/7796c132-8007-47e4-9e08-81b1f59a7928" width=200px alt="asddsfa" />

AnySense data storage format:
- Streamed Bluetooth Data (.bin)
- RGB video (.mp4)  
- Depth video (.mp4)
- Metric depth frames (*.bin)
- Pose Data (.txt)
   
## Setting up locally
1. Clone the github repository: 
    ```
    git clone https://github.com/NYU-robot-learning/AnySense.git
    ```
2. Install [XCode](https://developer.apple.com/xcode/) and open the repository in XCode. 

3. In the app settings, navigate to the "Signing & Capabilities" section. Make sure the "Automatically manage signing" checkbox is checked. Add your account and set a unique bundle identifier.
   
4. Plug in your IOS device to your Mac, and follow instructions for trusting the computer, [enabling Developer mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device). You should now be able to build the app.

## Contact me
Questions about AnySense? Contact: raunaqbhirangi@nyu.edu

The team at Generalizable Robotics and AI Lab, NYU: [Raunaq Bhirangi](https://raunaqbhirangi.nyu.edu), Zeyu (Michael) Bian, [Venkatesh Pattabiraman](https://venkyp.com), [Haritheja Etukuru](https://haritheja.com), [Mehmet Enes Erciyes](https://eneserciyes.github.io), Krish Mehta, [Nur Muhammad Mahi Shafiullah](https://mahis.life), [Lerrel Pinto](https://www.lerrelpinto.com)
