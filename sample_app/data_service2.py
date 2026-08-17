from flask_wtf.csrf import CSRFProtect
import re

# Enable CSRF protection globally on the Flask app
csrf = CSRFProtect(app)

@app.route('/update_profile', methods=['POST'])
def update_profile():
    email = request.form.get('email')
    user_id = request.form.get('user_id')
    
    if not email or not user_id:
        return jsonify({"error": "Missing parameters"}), 400
        
    # Validate email format
    if not re.match(r"[^@]+@[^@]+\.[^@]+", email):
        return jsonify({"error": "Invalid email format"}), 400
        
    # Validate user ID format
    try:
        user_id = int(user_id)
    except ValueError:
        return jsonify({"error": "Invalid user ID"}), 400
        
    # Simulate database update
    print(f"Updating email for user {user_id} to {email}")
    return jsonify({"status": "success", "email": email})