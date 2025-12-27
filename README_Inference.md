# Inference View

The inference view lets you run a point-conditioned CoreML policy on-device, visualize actions in AR, and inspect the gripper state. The purpose of this is to allow for us to be able to test the model without a robot, and get a sense of it's capability(vibe) with you acting as a robot arm, and evaluating in the wild based on the policy's conditioning task. The demo model loaded by default is a object pick-up policy. It is optimized for low-latency inference and small memory churn using shared pixel buffers and Accelerate for preprocessing.

## Technical Specifications

**Model Requirements:**
The system accepts CoreML models converted from our pipelines such as RUM/min-stretch. Models must process RGB input at 224×224 pixel resolution, though the original specification supported 256×256 pixels. Researchers requiring alternative resolutions can adjust the `modelInputSize` parameter and corresponding buffer allocations in `MLInferenceManager`.

The system supports temporal models with up to 3-frame rolling buffers, automatically managing sequence padding for consistency. Input tensors follow standard formats: `[1, 3, H, W]` for single-frame models or `[1, T, 3, H, W]` for temporal architectures, accompanied by goal tensors representing 3D spatial coordinates with shape inferred from model specifications.

Model outputs must provide 7-element vectors representing 6-DOF manipulation actions plus gripper state. For temporal models, the system extracts predictions from the final timestep, ensuring consistency with training assumptions while accommodating variable sequence lengths.

## App Pipeline

1) **Model load**: `ModelManager` provides the active compiled model and metadata (temporal frames, input/output names, goal requirement). A loading overlay is shown while this warms up.  
2) **Goal conditioning**: A user-tapped 3D goal in world space is transformed to the camera/labels frame just before inference (mapping: `[-x_cam, -z_cam + first-frame 0.02 offset, -y_cam]`). Required models skip inference until a goal exists.  
3) **Frame prep**: AR camera frames → vImage/Core Image resize to 224×224 ARGB → normalized MLMultiArray `[1,3,H,W]`. Gripper overlay is composited into the model input when USB streaming is OFF.  
4) **Temporal buffer**: Maintain up to 3 action frames.  
   - USB streaming ON: always roll the buffer; run by frequency (High/Med/Low/Minute) or first inference.  
   - USB streaming OFF (recording mode): buffer only when proximity trigger fires or on first/manual inference.  
5) **Input packing**: Build `[1,T,3,H,W]` with padding if fewer than T frames; build goal tensor matching the model-declared shape; assemble `MLDictionaryFeatureProvider`.  
6) **Inference**: Run off-main on a dedicated queue; track inference time; guard with a pending flag to avoid overlap.  
7) **Postprocess**: Extract joint actions (last timestep if temporal). Gripper value updates UI + overlay, and AR visualization updates the target pose (skipped in USB mode). Latest result is published for the UI card.

## UI/Controls

- **Set goal**: Tap “Set goal”, then tap in AR to place the 3D target.  
- **Start/stop**: App toggle enables/disables inference; model loading overlay appears when switching models.  
- **Manual step**: "Get next action" calls manual inference using the existing buffered frames. This is specifically useful if there's significant deviation from target, and user wants to realign and restart inferencing. This also helps check for robustness in the performance.
- **Visualization**: AR overlay shows the inferred pose (recording mode only). Gripper overlay image on-screen mirrors predicted gripper open/closed and shows an “iPhone Inferencing” badge when active.  
- **Status card**: `MLInferenceResultsView` shows gripper value and OPEN/CLOSED state.  

## How to Use Quickly

1) Ensure a compiled model is available (see min-stretch conversion flow) and enter the Inference tab. A demo model is already loaded up, trained on object pick-up tasks.
2) Enable AI inference from the settings view; wait for "Preparing Model…" to finish if shown.  
3) Tap "Set goal" and click on a pointplace the target in AR.  
4) Press Record, and start aligning the blue arrow to the red arrow (that changes from red to green as you get closer). As you align, the next action is inferenced. If next action is far off target, you can retry inferencing using the "Get next action" button.
5) Watch the AR pose updates and the gripper card/overlay for state and timing feedback.

## USB Streaming for Robot Control

The app can stream inference results directly to a robot via USB using the Record3D protocol. When USB streaming is enabled, the iPhone performs on-device inference and streams RGB frames, depth maps, camera poses, and predicted joint actions (7-DOF: 6-DOF manipulation + gripper state) to a connected computer. The robot server receives these action predictions in real-time and can execute them directly. To use this feature, enable "USB Streaming mode" in the Settings tab, connect your iOS device to your computer, and use the [anysense-streaming library](https://github.com/NYU-robot-learning/anysense-streaming/tree/dev/Krish) to receive the stream. The library provides Python and C++ bindings for receiving RGBD data, camera poses, and joint actions via `session.get_joint_actions()`.

## Implementation Notes: PyTorch to CoreML Conversion

Converting PyTorch models (RUM/min-stretch) to CoreML requires refactoring the loss function's forward method from a training-style interface to an inference-only path (`images, goals` → actions), replacing negative dimension indices with explicit positive ones, using slice notation to preserve tensor dimensions, and adding explicit type casts for `F.one_hot()` operations. A `CoreMLBranchStyleWrapper` encapsulates the model and loss function to provide a clean inference path. The conversion notebook is available in the [min-stretch repository's coreml branch](https://github.com/NYU-robot-learning/min-stretch/tree/coreml).
