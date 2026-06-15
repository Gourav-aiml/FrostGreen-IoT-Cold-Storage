"""
train_model.py  –  Cold Storage Fungal Risk Model Training
Run: python train_model.py
Outputs: fungal_risk_model.pkl, label_encoder.pkl
"""

import pandas as pd
from sklearn.model_selection import train_test_split, StratifiedKFold, cross_val_score
from sklearn.ensemble import RandomForestClassifier
from sklearn.metrics import accuracy_score, classification_report, confusion_matrix
from sklearn.preprocessing import LabelEncoder
import joblib

# ── Load dataset ──────────────────────────────────────────────
df = pd.read_csv("cold_storage_dataset.csv")
print(f"Dataset loaded: {df.shape[0]} rows, {df.shape[1]} columns")

# ── Feature engineering ───────────────────────────────────────
df["avg_temp"]  = (df["temp1"] + df["temp2"]) / 2
df["avg_hum"]   = (df["hum1"]  + df["hum2"])  / 2
df["avg_gas"]   = (df["gas1"]  + df["gas2"])  / 2
df["temp_diff"] = abs(df["temp1"] - df["temp2"])
df["hum_diff"]  = abs(df["hum1"]  - df["hum2"])
df["gas_diff"]  = abs(df["gas1"]  - df["gas2"])

FEATURE_COLS = [
    "temp1", "temp2",
    "hum1",  "hum2",
    "gas1",  "gas2",
    "avg_temp", "avg_hum", "avg_gas",
    "temp_diff", "hum_diff", "gas_diff",
]

X = df[FEATURE_COLS]
y = df["fungal_risk"]

print(f"\nClass distribution:")
print(y.value_counts().to_string())

# ── Label encoding ────────────────────────────────────────────
label_encoder = LabelEncoder()
y_encoded     = label_encoder.fit_transform(y)
print(f"\nEncoded classes: {dict(zip(label_encoder.classes_, label_encoder.transform(label_encoder.classes_)))}")

# ── Train / test split ────────────────────────────────────────
X_train, X_test, y_train, y_test = train_test_split(
    X, y_encoded, test_size=0.2, random_state=42, stratify=y_encoded
)
print(f"\nTrain: {len(X_train)}  |  Test: {len(X_test)}")

# ── Model ─────────────────────────────────────────────────────
# Tuned hyperparameters:
#   n_estimators=300   : enough trees for stable voting
#   max_depth=12       : deep enough for complex patterns, not overfitting
#   min_samples_split=5: prevents splits on tiny node groups
#   min_samples_leaf=2 : each leaf needs at least 2 samples
#   max_features=sqrt  : randomises features per split (prevents correlation)
#   class_weight=balanced: handles unequal class distribution
model = RandomForestClassifier(
    n_estimators=300,
    max_depth=12,
    min_samples_split=5,
    min_samples_leaf=2,
    max_features="sqrt",
    class_weight="balanced",
    random_state=42,
    n_jobs=-1
)
model.fit(X_train, y_train)

# ── Evaluation ────────────────────────────────────────────────
y_pred = model.predict(X_test)
acc    = accuracy_score(y_test, y_pred)
print(f"\n{'='*45}")
print(f"Test Accuracy: {acc * 100:.2f}%")
print(f"{'='*45}")

print("\nClassification Report:")
print(classification_report(
    y_test, y_pred,
    target_names=label_encoder.classes_,
    zero_division=0
))

print("Confusion Matrix:")
cm = confusion_matrix(y_test, y_pred)
print(f"  Classes: {list(label_encoder.classes_)}")
print(cm)

# ── 5-Fold Cross Validation ───────────────────────────────────
print("\n5-Fold Stratified Cross Validation:")
skf    = StratifiedKFold(n_splits=5, shuffle=True, random_state=42)
scores = cross_val_score(model, X, y_encoded, cv=skf, scoring="accuracy")
print(f"  Fold scores: {[round(s*100,2) for s in scores]}")
print(f"  Mean: {scores.mean()*100:.2f}%   Std: {scores.std()*100:.2f}%")

# ── Feature importance ────────────────────────────────────────
print("\nFeature Importances (ranked):")
importances = sorted(
    zip(FEATURE_COLS, model.feature_importances_),
    key=lambda x: -x[1]
)
for fname, imp in importances:
    bar = "█" * int(imp * 60)
    print(f"  {fname:<12}  {imp:.4f}  {bar}")

# ── Save ──────────────────────────────────────────────────────
joblib.dump(model,         "fungal_risk_model.pkl")
joblib.dump(label_encoder, "label_encoder.pkl")
print("\n✓ fungal_risk_model.pkl saved")
print("✓ label_encoder.pkl     saved")
