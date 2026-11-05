/// Bangladesh's 64 districts, for delivery address suggestions.
const bdDistricts = [
  'Dhaka', 'Chattogram', 'Gazipur', 'Narayanganj', 'Sylhet', 'Rajshahi', 'Khulna', 'Rangpur', 'Mymensingh',
  'Barishal', 'Cumilla', 'Bogura', "Cox's Bazar", 'Bagerhat', 'Bandarban', 'Barguna', 'Bhola',
  'Brahmanbaria', 'Chandpur', 'Chapai Nawabganj', 'Chuadanga', 'Dinajpur', 'Faridpur', 'Feni', 'Gaibandha',
  'Gopalganj', 'Habiganj', 'Jamalpur', 'Jashore', 'Jhalokathi', 'Jhenaidah', 'Joypurhat', 'Khagrachhari',
  'Kishoreganj', 'Kurigram', 'Kushtia', 'Lakshmipur', 'Lalmonirhat', 'Madaripur', 'Magura', 'Manikganj',
  'Meherpur', 'Moulvibazar', 'Munshiganj', 'Naogaon', 'Narail', 'Narsingdi', 'Natore', 'Netrokona',
  'Nilphamari', 'Noakhali', 'Pabna', 'Panchagarh', 'Patuakhali', 'Pirojpur', 'Rajbari', 'Rangamati',
  'Satkhira', 'Shariatpur', 'Sherpur', 'Sirajganj', 'Sunamganj', 'Tangail', 'Thakurgaon',
];

bool isInsideDhaka(String? city) {
  final c = (city ?? '').trim().toLowerCase();
  return c.isEmpty || c == 'dhaka' || c == 'ঢাকা';
}
