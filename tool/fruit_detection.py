#!/usr/bin/env python3
"""
Standalone YOLOv8 Fruit Detection Inference Script

Usage:
    python fruit_detection.py <image_path> [confidence] [model_path]

Example:
    python fruit_detection.py image.jpg 0.5
    python fruit_detection.py image.jpg 0.5 models/best.pt
"""

import sys
import json
import argparse
from pathlib import Path
from typing import Dict, List, Any

try:
    from ultralytics import YOLO
    import cv2
    import numpy as np
except ImportError as e:
    print(json.dumps({
        "error": f"Missing dependency: {e}. Install with: pip install ultralytics torch torchvision opencv-python",
        "success": False
    }))
    sys.exit(1)


class FruitDetector:
    """YOLOv8 Fruit Detection Engine"""
    
    def __init__(self, model_path: str = "models/best.pt"):
        """Initialize the detector with a model."""
        if not Path(model_path).exists():
            raise FileNotFoundError(f"Model not found: {model_path}")
        
        self.model_path = model_path
        self.model = None
        self._load_model()
    
    def _load_model(self):
        """Load the YOLO model."""
        try:
            self.model = YOLO(self.model_path)
            print(f"✓ Model loaded: {self.model_path}", file=sys.stderr)
        except Exception as e:
            raise RuntimeError(f"Failed to load model: {e}")
    
    def detect(
        self,
        image_path: str,
        confidence: float = 0.5,
        verbose: bool = False
    ) -> Dict[str, Any]:
        """
        Run inference on an image.
        
        Args:
            image_path: Path to the image file
            confidence: Confidence threshold (0.0-1.0)
            verbose: Print debug information
        
        Returns:
            Dictionary with detections and metadata
        """
        if not Path(image_path).exists():
            raise FileNotFoundError(f"Image not found: {image_path}")
        
        try:
            # Run inference
            results = self.model.predict(
                source=image_path,
                conf=confidence,
                verbose=False
            )
            
            if not results:
                return {
                    "detections": [],
                    "success": False,
                    "error": "No results from model"
                }
            
            result = results[0]
            
            # Extract detections
            detections = []
            for i, box in enumerate(result.boxes):
                class_id = int(box.cls)
                class_name = result.names.get(class_id, f"class_{class_id}")
                confidence_score = float(box.conf)
                
                # Bounding box coordinates
                x1, y1, x2, y2 = [float(v) for v in box.xyxy[0].tolist()]
                
                # Center coordinates and dimensions
                cx = (x1 + x2) / 2
                cy = (y1 + y2) / 2
                width = x2 - x1
                height = y2 - y1
                
                # Normalize to 0-1
                img_h, img_w = result.orig_shape
                cx_norm = cx / img_w
                cy_norm = cy / img_h
                w_norm = width / img_w
                h_norm = height / img_h
                
                detection = {
                    "id": i,
                    "name": class_name,
                    "confidence": confidence_score,
                    "box": [x1, y1, x2, y2],  # Pixel coordinates
                    "x": cx_norm,  # Normalized center x
                    "y": cy_norm,  # Normalized center y
                    "width": w_norm,  # Normalized width
                    "height": h_norm,  # Normalized height
                    "pixel_x": cx,
                    "pixel_y": cy,
                    "pixel_width": width,
                    "pixel_height": height,
                }
                detections.append(detection)
            
            if verbose:
                print(f"✓ Detected {len(detections)} objects", file=sys.stderr)
            
            # Return results
            return {
                "detections": detections,
                "success": True,
                "image_width": result.orig_shape[1],
                "image_height": result.orig_shape[0],
                "model_info": {
                    "model_path": self.model_path,
                    "confidence_threshold": confidence,
                    "num_classes": len(result.names),
                    "classes": result.names,
                }
            }
        
        except Exception as e:
            return {
                "detections": [],
                "success": False,
                "error": str(e)
            }
    
    def detect_batch(
        self,
        image_paths: List[str],
        confidence: float = 0.5,
        verbose: bool = False
    ) -> List[Dict[str, Any]]:
        """Run inference on multiple images."""
        results = []
        for image_path in image_paths:
            result = self.detect(image_path, confidence, verbose)
            result["image_path"] = image_path
            results.append(result)
        return results


def main():
    """Command-line interface."""
    parser = argparse.ArgumentParser(
        description="YOLOv8 Fruit Detection",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python fruit_detection.py image.jpg
  python fruit_detection.py image.jpg 0.5
  python fruit_detection.py image.jpg 0.5 models/best.pt
  python fruit_detection.py image.jpg --confidence 0.75 --model models/best.pt
        """
    )
    
    parser.add_argument("image", help="Path to image file")
    parser.add_argument("confidence", nargs="?", type=float, default=0.5,
                        help="Confidence threshold (default: 0.5)")
    parser.add_argument("--model", "-m", default="models/best.pt",
                        help="Path to model file (default: models/best.pt)")
    parser.add_argument("--verbose", "-v", action="store_true",
                        help="Verbose output")
    parser.add_argument("--json", "-j", action="store_true",
                        help="Output as JSON")
    
    args = parser.parse_args()
    
    try:
        # Initialize detector
        detector = FruitDetector(model_path=args.model)
        
        # Run inference
        result = detector.detect(
            image_path=args.image,
            confidence=args.confidence,
            verbose=args.verbose
        )
        
        # Output results
        if args.json or len(sys.argv) <= 2:
            # JSON output (default for non-interactive use)
            print(json.dumps(result, indent=2))
        else:
            # Pretty output
            if result["success"]:
                print(f"\n✓ Inference successful ({args.image})")
                print(f"Image size: {result['image_width']}x{result['image_height']}")
                print(f"Detections: {len(result['detections'])}\n")
                
                for det in result["detections"]:
                    print(f"  [{det['id']}] {det['name']}: {det['confidence']:.1%} confidence")
                    print(f"      Box: {det['box']}")
                    print(f"      Pixel: ({det['pixel_x']:.1f}, {det['pixel_y']:.1f})")
            else:
                print(f"✗ Inference failed: {result.get('error', 'Unknown error')}")
        
        return 0 if result["success"] else 1
    
    except Exception as e:
        error_output = {
            "success": False,
            "error": str(e)
        }
        print(json.dumps(error_output, indent=2))
        return 1


if __name__ == "__main__":
    sys.exit(main())
