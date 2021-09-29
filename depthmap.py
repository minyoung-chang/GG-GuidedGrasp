import numpy as np
import matplotlib.pyplot as plt
import PIL
with open('./depthmap_data/data1_scene.txt') as f:
    lines = f.readlines()

depthImage = []
for line in lines:
    depthImageRow = []
    for val in line.split(','):
        val = val.replace('[', '')
        val = val.replace(']', '')
        val = val.replace(' ', '')
        depthImageRow.append(float(val) * 255)
    depthImage.append(depthImageRow)
depthImage = np.array(depthImage, dtype=np.ubyte)
depthImage = np.fliplr(depthImage.T)
image = PIL.Image.fromarray(depthImage, "L")
image.show()
