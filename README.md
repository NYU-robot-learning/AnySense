
# AnySense
[AnySense](https://anysense.app) is an iPhone application that integrates the iPhone's sensory suite with external multisensory inputs via Bluetooth and wired interfaces, enabling both offline data collection and online streaming to robots. Currently, we record RGB and depth videos, metric depth frames, streamed Bluetooth data appended into a binary file and timestamped pose data as a set `.txt` file. Example streaming code for streaming Bluetooth data can be found on [AnySkin](https://any-skin.github.io). We also allow for USB streaming by simply connecting the iPhone to your computer and using this [accompanying library](https://github.com/NYU-robot-learning/anysense-streaming) forked from the excellent [record3d](https://github.com/marek-simonik/record3d) library.

## App Screenshots

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
2. In the app settings, navigate to the "Signing & Capabilities" section. Make sure the "Automatically manage signing" checkbox is checked.

3. Add your account and set a unique bundle identifier.
   
4. Plug in your IOS device to your Mac, and follow instructions for trusting the computer, [enabling Developer mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device). You should now be able to build the app.

## Contact me
Questions about AnySense? Contact: raunaqbhirangi@nyu.edu

The team at Generalizable Robotics and AI Lab, NYU: [Raunaq Bhirangi](https://raunaqbhirangi.nyu.edu), Zeyu (Michael) Bian, [Venkatesh Pattabiraman](https://venkyp.com), [Haritheja Etukuru](https://haritheja.com), [Mehmet Enes Erciyes](https://eneserciyes.github.io), [Nur Muhammad Mahi Shafiullah](https://mahis.life), [Lerrel Pinto](https://www.lerrelpinto.com)
